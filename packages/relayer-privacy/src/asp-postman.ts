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
// Still deferred to slice 4b:
//   • Durable persistence of the cursor + leaf set (currently in-memory,
//     so restarts re-scan from FROM_BLOCK each time).
//   • Reorg-safety beyond the finality-confirmations window.
//   • Real ASP screening (this is the permissive variant — every observed
//     label is approved; mainnet swaps in a real screening provider).

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

// ---------------------------------------------------------------------------
// ABIs (minimal — just the events + writes we need)
// ---------------------------------------------------------------------------

const ENTRYPOINT_ABI = [
  {
    type: "event",
    name: "PoolRegistered",
    inputs: [
      { name: "_pool",  type: "address", indexed: true  },
      { name: "_asset", type: "address", indexed: true  },
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
  /** Confirmations to wait before treating a block as final. */
  finalityConfirmations: bigint;
  /** Maximum block range per `getContractEvents` call (RPC pagination). */
  maxRangePerCall: bigint;
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
    pollIntervalSeconds:   Number(Bun.env["POLL_INTERVAL_SECONDS"] ?? 30),
    fromBlock:             BigInt(Bun.env["FROM_BLOCK"] ?? "0"),
    finalityConfirmations: BigInt(Bun.env["FINALITY_CONFIRMATIONS"] ?? "5"),
    maxRangePerCall:       BigInt(Bun.env["MAX_RANGE_PER_CALL"] ?? "5000"),
    dryRun:                Bun.env["DRY_RUN"] === "true",
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
}

function compareCanonical(a: CanonicalDeposit, b: CanonicalDeposit): number {
  if (a.blockNumber !== b.blockNumber)
    return a.blockNumber < b.blockNumber ? -1 : 1;
  if (a.transactionIndex !== b.transactionIndex)
    return a.transactionIndex - b.transactionIndex;
  return a.logIndex - b.logIndex;
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
  /** The published Merkle tree (LeanIMT over Poseidon). */
  tree: LeanIMT<bigint>;
  dirty: boolean;
}

function newState(): IndexerState {
  return {
    cursor:  0n,
    pools:   [],
    applied: new Set<string>(),
    tree:    new LeanIMT<bigint>((a: bigint, b: bigint) => poseidon([a, b])),
    dirty:   false,
  };
}

function applyDeposits(state: IndexerState, deposits: CanonicalDeposit[]): void {
  deposits.sort(compareCanonical);
  for (const d of deposits) {
    const key = `${d.blockNumber}:${d.transactionIndex}:${d.logIndex}`;
    if (state.applied.has(key)) continue;
    state.applied.add(key);
    state.tree.insert(d.label);
    state.dirty = true;
  }
}

async function fetchRange(
  client: PublicClient,
  cfg: PostmanConfig,
  pools: Address[],
  fromBlock: bigint,
  toBlock:   bigint,
): Promise<CanonicalDeposit[]> {
  const collected: CanonicalDeposit[] = [];
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
        const a = ev.args as { _label?: bigint };
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
        collected.push({
          blockNumber:      ev.blockNumber,
          transactionIndex: ev.transactionIndex,
          logIndex:         ev.logIndex,
          pool:             ev.address,
          label:            a._label,
        });
      }
    }

    cursor = end + 1n;
  }
  return collected;
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
    dryRun:                cfg.dryRun,
  });

  const state = newState();
  state.cursor = cfg.fromBlock === 0n ? 0n : cfg.fromBlock - 1n;

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
        const fresh = await fetchRange(publicClient, cfg, state.pools, from, finalized);
        applyDeposits(state, fresh);
        state.cursor = finalized;
      }

      if (state.dirty && state.tree.size > 0) {
        const root = state.tree.root;
        const cid = `permissive-root-${state.tree.size}-${Date.now().toString(36)}`
          .padEnd(32, "x")
          .slice(0, 64);
        log("info", "publishing root", {
          root: `0x${root.toString(16)}`, size: state.tree.size, dryRun: cfg.dryRun,
        });
        if (!cfg.dryRun) {
          const txHash = await walletClient.writeContract({
            chain: null,
            account,
            address: cfg.entrypoint,
            abi: ENTRYPOINT_ABI,
            functionName: "updateRoot",
            args: [root, cid],
          });
          log("info", "updateRoot tx sent", { txHash });
        }
        state.dirty = false;
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
  type CanonicalDeposit,
  type IndexerState,
};

if (import.meta.main) {
  main().catch((err) => {
    console.error("[asp-postman] fatal:", err);
    process.exit(1);
  });
}
