// SPDX-License-Identifier: AGPL-3.0-only
//
// Permissive ASP postman — testnet only.
//
// Codex-r2 HIGH redesign: this version is a CURSOR-BASED CANONICAL
// INDEXER, not a set of independent per-pool watchers. Publishing an
// ASP root that off-chain clients cannot reproduce from chain history
// would make valid testnet withdrawals fail; that risk is eliminated
// here by:
//
//   1. Discovering pools from FROM_BLOCK onward via
//      `Entrypoint.PoolRegistered`. PoolRemoved does NOT desubscribe —
//      outstanding shielded balances remain withdrawable.
//   2. Fetching all pool `Deposited` events over finalized block ranges
//      and sorting them by `(blockNumber, transactionIndex, logIndex)`
//      across pools before insertion. The on-chain `latestRoot()` we
//      publish is therefore a function of canonical chain history alone.
//   3. Maintaining a single cursor (`lastProcessedBlock`) and re-running
//      the range fetch on each tick, so restarts converge to the same
//      tree as long as `FROM_BLOCK` is below the first deposit.
//
// Still deferred:
//   • Reorg-safety beyond the finality-confirmations window.
//   • Real ASP screening (this is the permissive variant — every observed
//     label is approved; mainnet swaps in a real screening provider).
//
// Track C1 (this slice): cursor + leaf set + discovered-pools are now
// persisted to SQLite via `./persistence.ts`. On restart the postman
// rehydrates state from `${DATA_DIR}/postman.db` (default `./.relayer-state/`),
// replays leaves into a fresh LeanIMT in canonical insertion order, and
// resumes scanning from the stored cursor. The DB is per-process; honor
// the single-writer constraint (README §single-writer) by never pointing
// two postman processes at the same DB file.

import { LeanIMT } from "@zk-kit/lean-imt";
import { poseidon } from "maci-crypto/build/ts/hashing.js";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { PostmanStore } from "./persistence.js";

// ---------------------------------------------------------------------------
// ABIs (minimal — just the events + writes we need)
// ---------------------------------------------------------------------------

// IMPORTANT (codex-r3 HIGH #1): the Solidity event has NO indexed fields:
//   event PoolRegistered(IPrivacyPool _pool, IERC20 _asset, uint256 _scope);
// All three values land in `data`, none in topics. An ABI that marks any
// of them as `indexed: true` causes viem to decode against the wrong
// topic/data layout and `_pool` comes back missing — pool discovery
// silently fails, no labels are indexed, the postman publishes a useless
// ASP root, and real withdrawals revert `IncorrectASPRoot`.
const ENTRYPOINT_ABI = [
  {
    type: "event",
    name: "PoolRegistered",
    inputs: [
      { name: "_pool",  type: "address", indexed: false },
      { name: "_asset", type: "address", indexed: false },
      { name: "_scope", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "function",
    name: "updateRoot",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_root",    type: "uint256" },
      { name: "_ipfsCID", type: "string"  },
    ],
    outputs: [{ name: "_index", type: "uint256" }],
  },
  {
    type: "function",
    name: "latestRoot",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "_root", type: "uint256" }],
  },
] as const;

const PRIVACY_POOL_ABI = [
  {
    type: "event",
    name: "Deposited",
    inputs: [
      { name: "_depositor",         type: "address", indexed: true },
      { name: "_commitment",        type: "uint256", indexed: false },
      { name: "_label",             type: "uint256", indexed: false },
      { name: "_value",             type: "uint256", indexed: false },
      { name: "_precommitmentHash", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "LeafInserted",
    inputs: [
      { name: "_index", type: "uint256", indexed: false },
      { name: "_leaf",  type: "uint256", indexed: false },
      { name: "_root",  type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
] as const;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

interface PostmanConfig {
  rpcUrl: string;
  privateKey: Hex;
  entrypoint: Address;
  pollIntervalSeconds: number;
  /** Block from which we look for pools + their first deposits.
   *  Set to the FxPrivacyEntrypoint deploy block for best startup
   *  latency; setting it BELOW the first PoolRegistered event is also
   *  fine. Setting it ABOVE will lose history — see r2 finding HIGH. */
  fromBlock: bigint;
  /** Confirmations to wait before treating a block as final. The same
   *  value is used for both event scanning AND root publication so the
   *  publish path is at least as conservative as the indexer
   *  (codex-r4 HIGH). */
  finalityConfirmations: bigint;
  /** Maximum block range per `getContractEvents` call (RPC pagination). */
  maxRangePerCall: bigint;
  /** Max consecutive publish failures before the loop aborts. 0 = never
   *  abort (suitable for testnet operators who want manual triage).
   *  codex-r4: prevents silent spin on permanent role loss. */
  maxConsecutivePublishFailures: number;
  /** SQLite path for persisted cursor + leaves + pools. The directory is
   *  auto-created if missing. Track C1: restarts pick up where the last
   *  tick left off instead of re-scanning from FROM_BLOCK. */
  dbPath: string;
  dryRun: boolean;
}

function loadConfig(): PostmanConfig {
  const rpcUrl = Bun.env["RPC_URL"];
  const privateKey = Bun.env["PRIVATE_KEY"] as Hex | undefined;
  const entrypoint = Bun.env["ENTRYPOINT_ADDRESS"] as Address | undefined;
  if (!rpcUrl) throw new Error("RPC_URL is required");
  if (!privateKey) throw new Error("PRIVATE_KEY is required");
  if (!entrypoint) throw new Error("ENTRYPOINT_ADDRESS is required");
  return {
    rpcUrl,
    privateKey,
    entrypoint,
    pollIntervalSeconds:           Number(Bun.env["POLL_INTERVAL_SECONDS"] ?? 30),
    fromBlock:                     BigInt(Bun.env["FROM_BLOCK"] ?? "0"),
    finalityConfirmations:         BigInt(Bun.env["FINALITY_CONFIRMATIONS"] ?? "5"),
    maxRangePerCall:               BigInt(Bun.env["MAX_RANGE_PER_CALL"] ?? "5000"),
    maxConsecutivePublishFailures: Number(Bun.env["MAX_CONSECUTIVE_PUBLISH_FAILURES"] ?? 0),
    dbPath:                        Bun.env["DB_PATH"] ?? `${Bun.env["DATA_DIR"] ?? "./.relayer-state"}/postman.db`,
    dryRun:                        Bun.env["DRY_RUN"] === "true",
  };
}

function log(level: "info" | "warn" | "error", msg: string, ctx?: unknown): void {
  const line =
    `[${new Date().toISOString()}] ` +
    `[asp-postman] ` +
    `[${level}] ${msg}` +
    (ctx ? ` ${JSON.stringify(ctx, (_k, v) => typeof v === "bigint" ? v.toString() : v)}` : "");
  if (level === "error") console.error(line);
  else console.log(line);
}

// ---------------------------------------------------------------------------
// Canonical event record
// ---------------------------------------------------------------------------

interface CanonicalDeposit {
  blockNumber:      bigint;
  transactionIndex: number;
  logIndex:         number;
  pool:             Address;
  label:            bigint;
  commitment?:      bigint;
}

interface CanonicalStateLeaf {
  blockNumber:      bigint;
  transactionIndex: number;
  logIndex:         number;
  pool:             Address;
  leaf:             bigint;
}

function compareCanonicalPosition(
  a: { blockNumber: bigint; transactionIndex: number; logIndex: number },
  b: { blockNumber: bigint; transactionIndex: number; logIndex: number },
): number {
  if (a.blockNumber !== b.blockNumber)
    return a.blockNumber < b.blockNumber ? -1 : 1;
  if (a.transactionIndex !== b.transactionIndex)
    return a.transactionIndex - b.transactionIndex;
  return a.logIndex - b.logIndex;
}

function compareCanonical(a: CanonicalDeposit, b: CanonicalDeposit): number {
  return compareCanonicalPosition(a, b);
}

// ---------------------------------------------------------------------------
// Indexer state
// ---------------------------------------------------------------------------

interface IndexerState {
  /** Highest block fully scanned + applied to `tree`. */
  cursor: bigint;
  /** Known pools (in PoolRegistered order). */
  pools: Address[];
  /** Labels already in `tree`, by `${blockNumber}:${txIndex}:${logIndex}`. */
  applied: Set<string>;
  /** State leaves already persisted, by `${blockNumber}:${txIndex}:${logIndex}`. */
  stateApplied: Set<string>;
  /** Per-pool state leaf count, used to persist commitments in each pool's
   *  insertion order for relayExecute proof generation. */
  stateLeafCounts: Map<string, number>;
  /** The published Merkle tree (LeanIMT over Poseidon). */
  tree: LeanIMT<bigint>;
  /** Tree mutated since the last successfully-confirmed updateRoot. */
  dirty: boolean;
  /** Consecutive failed publish attempts. Codex-r4: lets the loop bail
   *  on persistent failure (e.g. permanent loss of ASP_POSTMAN role). */
  consecutivePublishFailures: number;
}

function newState(): IndexerState {
  return {
    cursor:                     0n,
    pools:                      [],
    applied:                    new Set<string>(),
    stateApplied:               new Set<string>(),
    stateLeafCounts:            new Map<string, number>(),
    tree:                       new LeanIMT<bigint>((a: bigint, b: bigint) => poseidon([a, b])),
    dirty:                      false,
    consecutivePublishFailures: 0,
  };
}

interface AppliedLeaf {
  /** Canonical insertion key `${blockNumber}:${txIndex}:${logIndex}`. */
  key: string;
  /** Commitment label inserted into the LeanIMT. */
  label: bigint;
  /** 0-indexed position in canonical insertion order (= tree size - 1
   *  after this insert). The persistence layer stores this so a restart
   *  can replay the leaves in the same order, deterministically rebuilding
   *  the tree. */
  order: number;
}

function applyDeposits(state: IndexerState, deposits: CanonicalDeposit[]): AppliedLeaf[] {
  deposits.sort(compareCanonical);
  const applied: AppliedLeaf[] = [];
  for (const d of deposits) {
    const key = `${d.blockNumber}:${d.transactionIndex}:${d.logIndex}`;
    if (state.applied.has(key)) continue;
    const order = state.tree.size;
    state.applied.add(key);
    state.tree.insert(d.label);
    state.dirty = true;
    applied.push({ key, label: d.label, order });
  }
  return applied;
}

interface AppliedStateLeaf {
  key: string;
  pool: Address;
  leaf: bigint;
  poolOrder: number;
}

function applyStateLeaves(state: IndexerState, leaves: CanonicalStateLeaf[]): AppliedStateLeaf[] {
  leaves.sort(compareCanonicalPosition);
  const applied: AppliedStateLeaf[] = [];
  for (const l of leaves) {
    const key = `${l.blockNumber}:${l.transactionIndex}:${l.logIndex}`;
    if (state.stateApplied.has(key)) continue;
    const poolKey = l.pool.toLowerCase();
    const poolOrder = state.stateLeafCounts.get(poolKey) ?? 0;
    state.stateLeafCounts.set(poolKey, poolOrder + 1);
    state.stateApplied.add(key);
    applied.push({ key, pool: l.pool, leaf: l.leaf, poolOrder });
  }
  return applied;
}

async function fetchRange(
  client: PublicClient,
  cfg: PostmanConfig,
  pools: Address[],
  fromBlock: bigint,
  toBlock:   bigint,
): Promise<{ deposits: CanonicalDeposit[]; stateLeaves: CanonicalStateLeaf[] }> {
  const deposits: CanonicalDeposit[] = [];
  const stateLeaves: CanonicalStateLeaf[] = [];
  // Page through [fromBlock, toBlock] respecting `maxRangePerCall`.
  let cursor = fromBlock;
  while (cursor <= toBlock) {
    const end = cursor + cfg.maxRangePerCall - 1n > toBlock
      ? toBlock
      : cursor + cfg.maxRangePerCall - 1n;

    // PoolRegistered (so we discover new pools mid-window).
    const registered = await client.getContractEvents({
      address:   cfg.entrypoint,
      abi:       ENTRYPOINT_ABI,
      eventName: "PoolRegistered",
      fromBlock: cursor,
      toBlock:   end,
    });
    for (const ev of registered) {
      const a = ev.args as { _pool?: Address };
      if (a._pool && !pools.includes(a._pool)) {
        pools.push(a._pool);
        log("info", "pool discovered", { pool: a._pool, block: String(ev.blockNumber ?? "n/a") });
      }
    }

    // Pool Deposited across every known pool in this window.
    if (pools.length > 0) {
      const events = await client.getContractEvents({
        address:   pools,
        abi:       PRIVACY_POOL_ABI,
        eventName: "Deposited",
        fromBlock: cursor,
        toBlock:   end,
      });
      for (const ev of events) {
        const a = ev.args as { _commitment?: bigint; _label?: bigint };
        if (typeof a._label !== "bigint") continue;
        // viem provides nullable block / index fields on logs; for
        // canonical ordering we require all three.
        if (ev.blockNumber == null || ev.transactionIndex == null || ev.logIndex == null) {
          log("warn", "skipping log with missing positional metadata", {
            pool: ev.address,
            block: String(ev.blockNumber ?? "n/a"),
          });
          continue;
        }
        deposits.push({
          blockNumber:      ev.blockNumber,
          transactionIndex: ev.transactionIndex,
          logIndex:         ev.logIndex,
          pool:             ev.address,
          label:            a._label,
          commitment:       a._commitment,
        });
      }

      const leafEvents = await client.getContractEvents({
        address:   pools,
        abi:       PRIVACY_POOL_ABI,
        eventName: "LeafInserted",
        fromBlock: cursor,
        toBlock:   end,
      });
      for (const ev of leafEvents) {
        const a = ev.args as { _leaf?: bigint };
        if (typeof a._leaf !== "bigint") continue;
        if (ev.blockNumber == null || ev.transactionIndex == null || ev.logIndex == null) {
          log("warn", "skipping state leaf log with missing positional metadata", {
            pool: ev.address,
            block: String(ev.blockNumber ?? "n/a"),
          });
          continue;
        }
        stateLeaves.push({
          blockNumber:      ev.blockNumber,
          transactionIndex: ev.transactionIndex,
          logIndex:         ev.logIndex,
          pool:             ev.address,
          leaf:             a._leaf,
        });
      }
    }

    cursor = end + 1n;
  }
  return { deposits, stateLeaves };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const cfg = loadConfig();

  const publicClient: PublicClient = createPublicClient({ transport: http(cfg.rpcUrl) });
  const account = privateKeyToAccount(cfg.privateKey);
  const walletClient: WalletClient = createWalletClient({
    account,
    transport: http(cfg.rpcUrl),
  });

  log("info", "starting permissive ASP postman (cursor mode)", {
    entrypoint:            cfg.entrypoint,
    poller:                account.address,
    pollIntervalSeconds:   cfg.pollIntervalSeconds,
    fromBlock:             cfg.fromBlock,
    finalityConfirmations: cfg.finalityConfirmations,
    dbPath:                cfg.dbPath,
    dryRun:                cfg.dryRun,
  });

  // Track C1: open the persistent store, then hydrate state from it.
  // If the DB is empty, we initialize from FROM_BLOCK as before. If it
  // has prior state, we replay leaves into a fresh LeanIMT and resume
  // the cursor — no FROM_BLOCK rescan on restart.
  const store = new PostmanStore(cfg.dbPath);
  const state = newState();
  const persisted = store.load();
  if (persisted.leaves.length > 0 || persisted.cursor > 0n || persisted.pools.length > 0) {
    state.cursor = persisted.cursor;
    state.pools = persisted.pools.slice();
    for (const leaf of persisted.leaves) {
      state.applied.add(leaf.key);
      state.tree.insert(leaf.label);
    }
    for (const leaf of persisted.stateLeaves) {
      state.stateApplied.add(leaf.key);
      const poolKey = leaf.pool.toLowerCase();
      const next = Math.max(state.stateLeafCounts.get(poolKey) ?? 0, leaf.poolOrder + 1);
      state.stateLeafCounts.set(poolKey, next);
    }
    log("info", "hydrated state from disk", {
      cursor:    state.cursor,
      pools:     state.pools.length,
      treeSize:  state.tree.size,
      treeRoot:  state.tree.size > 0 ? `0x${state.tree.root.toString(16)}` : "(empty)",
    });
    // Mark dirty so the first tick reconciles vs on-chain `latestRoot`.
    state.dirty = state.tree.size > 0;
  } else {
    state.cursor = cfg.fromBlock === 0n ? 0n : cfg.fromBlock - 1n;
  }

  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const head = await publicClient.getBlockNumber();
      const finalized = head > cfg.finalityConfirmations
        ? head - cfg.finalityConfirmations
        : 0n;

      if (state.cursor < finalized) {
        const from = state.cursor + 1n;
        log("info", "scanning canonical range", {
          from, to: finalized, knownPools: state.pools.length, treeSize: state.tree.size,
        });
        const knownPoolsBefore = state.pools.length;
        const fresh = await fetchRange(publicClient, cfg, state.pools, from, finalized);
        const applied = applyDeposits(state, fresh.deposits);
        const appliedStateLeaves = applyStateLeaves(state, fresh.stateLeaves);
        state.cursor = finalized;

        // Track C1: persist range outcomes atomically. We persist BEFORE
        // attempting publication so a crash between insert and publish
        // recovers cleanly (next start sees the same tree, marks dirty,
        // retries). The transaction is local-only — no network IO.
        store.transaction(() => {
          // New pools first (the discovered order may include some we
          // already saw — recordPool is idempotent).
          for (let i = knownPoolsBefore; i < state.pools.length; i++) {
            store.recordPool(state.pools[i]!);
          }
          for (const leaf of applied) {
            store.appendLeaf(leaf.key, leaf.label, leaf.order);
          }
          for (const leaf of appliedStateLeaves) {
            store.appendStateLeaf(leaf.key, leaf.pool, leaf.leaf, leaf.poolOrder);
          }
          store.setCursor(state.cursor);
        });
      }

      // Codex-r4 HIGH: reconcile against on-chain `latestRoot()` BEFORE
      // deciding whether to publish. Single-writer mode (the only mode
      // we support in v1 — see README) treats ANY mismatch as our own
      // silent failure (reorg, dropped receipt) and re-marks dirty so
      // the next branch republishes.
      //
      // Codex-r7: we deliberately do NOT ship multi-writer mode in v1.
      // Safe multi-writer publication requires an on-chain compare-and-
      // set (`updateRootIfLatest(expected, new, cid)`), which would
      // touch the vendored Entrypoint. Until that lands, the postman
      // assumes it is the sole holder of the ASP_POSTMAN role on the
      // entrypoint. The runbook documents this constraint.
      if (state.tree.size > 0 && !state.dirty) {
        try {
          const onchain = await publicClient.readContract({
            address:      cfg.entrypoint,
            abi:          ENTRYPOINT_ABI,
            functionName: "latestRoot",
          });
          if (onchain !== state.tree.root) {
            log("warn", "on-chain root drift; re-marking dirty (single-writer mode)", {
              onchain: `0x${onchain.toString(16)}`,
              local:   `0x${state.tree.root.toString(16)}`,
            });
            state.dirty = true;
          }
        } catch (err) {
          // Pre-publish: latestRoot() reverts with NoRootsAvailable when
          // no root has ever been pushed. That's normal on a fresh chain
          // — just publish.
          if (!String(err).includes("NoRootsAvailable")) {
            log("warn", "latestRoot() reconcile failed (continuing)", { err: String(err) });
          }
          state.dirty = true;
        }
      }

      if (state.dirty && state.tree.size > 0) {
        const root = state.tree.root;
        const cid = `permissive-root-${state.tree.size}-${Date.now().toString(36)}`
          .padEnd(32, "x")
          .slice(0, 64);
        log("info", "publishing root", {
          root: `0x${root.toString(16)}`, size: state.tree.size, dryRun: cfg.dryRun,
        });
        if (cfg.dryRun) {
          state.dirty = false;
          state.consecutivePublishFailures = 0;
        } else {
          // Codex-r5 HIGH #1: wrap the ENTIRE publish attempt (incl.
          // writeContract send) in one failure-accounted try. Pre-r5,
          // send-side throws (bad key, RPC unreachable, preflight
          // revert) skipped the consecutivePublishFailures counter and
          // could spin forever even when MAX_CONSECUTIVE_PUBLISH_FAILURES
          // was set non-zero.
          let publishOk = false;
          try {
            const txHash = await walletClient.writeContract({
              chain: null,
              account,
              address: cfg.entrypoint,
              abi: ENTRYPOINT_ABI,
              functionName: "updateRoot",
              args: [root, cid],
            });
            log("info", "updateRoot tx sent, awaiting finality", {
              txHash, confirmations: cfg.finalityConfirmations,
            });

            const receipt = await publicClient.waitForTransactionReceipt({
              hash: txHash,
              confirmations: Number(cfg.finalityConfirmations),
            });
            publishOk = receipt.status === "success";
            if (!publishOk) {
              log("error", "updateRoot receipt non-success", {
                txHash, status: receipt.status,
              });
            } else {
              log("info", "updateRoot finalized", {
                txHash, block: String(receipt.blockNumber),
                confirmations: cfg.finalityConfirmations,
              });
            }
          } catch (err) {
            log("error", "updateRoot attempt failed (will retry)", {
              err: String(err),
            });
          }

          if (publishOk) {
            state.dirty = false;
            state.consecutivePublishFailures = 0;
          } else {
            state.consecutivePublishFailures += 1;
            log("warn", "publish failed; keeping dirty=true", {
              consecutiveFailures: state.consecutivePublishFailures,
              maxBeforeAbort:      cfg.maxConsecutivePublishFailures,
            });
            if (
              cfg.maxConsecutivePublishFailures > 0 &&
              state.consecutivePublishFailures >= cfg.maxConsecutivePublishFailures
            ) {
              log("error", "MAX_CONSECUTIVE_PUBLISH_FAILURES exceeded — aborting", {
                count: state.consecutivePublishFailures,
              });
              process.exit(2);
            }
          }
        }
      }
    } catch (err) {
      log("error", "tick failed (will retry)", { err: String(err) });
    }

    await Bun.sleep(cfg.pollIntervalSeconds * 1000);
  }
}

// ---------------------------------------------------------------------------
// Exported for unit tests — the canonical-ordering logic is the heart of
// this service and we want to exercise it without an RPC.
// ---------------------------------------------------------------------------

export {
  applyDeposits,
  compareCanonical,
  newState,
  type AppliedLeaf,
  type CanonicalDeposit,
  type IndexerState,
};

if (import.meta.main) {
  main().catch((err) => {
    console.error("[asp-postman] fatal:", err);
    process.exit(1);
  });
}
