// SPDX-License-Identifier: AGPL-3.0-only
//
// Permissive ASP postman — testnet only.
//
// Watches `IPrivacyPool.Deposited` events (NOT entrypoint Deposited — the
// entrypoint event omits the per-deposit `_label` that the withdrawal
// circuit proves membership of). Maintains an in-memory LeanIMT over the
// observed labels, then publishes a permissive ASP root via
// `Entrypoint.updateRoot()` so any valid commitment is "approved" for
// withdrawal.
//
// Codex-r1 HIGH #2: prior skeleton used the entrypoint Deposited event +
// commitment as leaf, which would NOT match real withdrawal proofs
// (those bind `label`, not `commitment`).
//
// Pool discovery: listens for `PoolRegistered(pool, asset, scope)` and
// `PoolRemoved(pool, asset, scope)` on the entrypoint, maintains a live
// set of pool addresses, and subscribes to each pool's Deposited event.
//
// Persistence + backfill (slice 4b): the current skeleton holds the
// LeanIMT entirely in memory; restarts re-build it from chain history at
// startup. A real deployment would persist the leaf set + last-processed
// block to durable storage.

import { LeanIMT } from "@zk-kit/lean-imt";
import { poseidon } from "maci-crypto/build/ts/hashing.js";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hex,
  type Log,
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
    type: "event",
    name: "PoolRemoved",
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
      { name: "_depositor",        type: "address", indexed: true },
      { name: "_commitment",       type: "uint256", indexed: false },
      { name: "_label",            type: "uint256", indexed: false },
      { name: "_value",            type: "uint256", indexed: false },
      { name: "_precommitmentHash",type: "uint256", indexed: false },
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
  /** Block from which to backfill on startup; 0 = beginning. */
  fromBlock: bigint;
  /** If true, do not actually broadcast — just log. */
  dryRun: boolean;
}

function loadConfig(): PostmanConfig {
  const rpcUrl = Bun.env["RPC_URL"];
  const privateKey = Bun.env["PRIVATE_KEY"] as Hex | undefined;
  const entrypoint = Bun.env["ENTRYPOINT_ADDRESS"] as Address | undefined;
  const pollIntervalSeconds = Number(Bun.env["POLL_INTERVAL_SECONDS"] ?? 30);
  const fromBlock = BigInt(Bun.env["FROM_BLOCK"] ?? "0");
  if (!rpcUrl) throw new Error("RPC_URL is required");
  if (!privateKey) throw new Error("PRIVATE_KEY is required");
  if (!entrypoint) throw new Error("ENTRYPOINT_ADDRESS is required");
  return {
    rpcUrl,
    privateKey,
    entrypoint,
    pollIntervalSeconds,
    fromBlock,
    dryRun: Bun.env["DRY_RUN"] === "true",
  };
}

function log(level: "info" | "warn" | "error", msg: string, ctx?: unknown): void {
  const line =
    `[${new Date().toISOString()}] ` +
    `[asp-postman] ` +
    `[${level}] ${msg}` +
    (ctx ? ` ${JSON.stringify(ctx)}` : "");
  if (level === "error") console.error(line);
  else console.log(line);
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

  log("info", "starting permissive ASP postman", {
    entrypoint: cfg.entrypoint,
    poller: account.address,
    pollIntervalSeconds: cfg.pollIntervalSeconds,
    fromBlock: String(cfg.fromBlock),
    dryRun: cfg.dryRun,
  });

  // The LeanIMT we publish. Hashes via Poseidon — identical Merkle math
  // to the on-chain InternalLeanIMT in contracts/lib/lean-imt/.
  const tree = new LeanIMT<bigint>((a: bigint, b: bigint) => poseidon([a, b]));
  const observedLabels = new Set<bigint>();
  const watchedPools = new Set<Address>();
  let dirty = false;

  function noteLabel(label: bigint): void {
    if (observedLabels.has(label)) return;
    observedLabels.add(label);
    tree.insert(label);
    dirty = true;
  }

  async function subscribePool(pool: Address): Promise<void> {
    if (watchedPools.has(pool)) return;
    watchedPools.add(pool);
    log("info", "subscribing to pool", { pool });

    // Backfill historical deposits from the configured block onward.
    try {
      const past = await publicClient.getContractEvents({
        address: pool,
        abi: PRIVACY_POOL_ABI,
        eventName: "Deposited",
        fromBlock: cfg.fromBlock,
        toBlock: "latest",
      });
      for (const ev of past) {
        const a = (ev as unknown as { args: { _label: bigint } }).args;
        if (typeof a._label === "bigint") noteLabel(a._label);
      }
      log("info", "pool backfilled", { pool, leaves: tree.size });
    } catch (err) {
      log("warn", "pool backfill failed (will rely on live watch)", { pool, err: String(err) });
    }

    // Live subscription.
    publicClient.watchContractEvent({
      address: pool,
      abi: PRIVACY_POOL_ABI,
      eventName: "Deposited",
      onLogs(logs: Log[]) {
        for (const ev of logs) {
          const a = (ev as unknown as { args: { _label: bigint } }).args;
          if (typeof a._label !== "bigint") continue;
          noteLabel(a._label);
          log("info", "label observed", {
            pool,
            label: `0x${a._label.toString(16)}`,
            size: tree.size,
          });
        }
      },
      onError(err: unknown) {
        log("error", "pool watch error", { pool, err: String(err) });
      },
    });
  }

  // Bootstrap: backfill PoolRegistered to find pools that already exist,
  // then watch live PoolRegistered + PoolRemoved.
  try {
    const past = await publicClient.getContractEvents({
      address: cfg.entrypoint,
      abi: ENTRYPOINT_ABI,
      eventName: "PoolRegistered",
      fromBlock: cfg.fromBlock,
      toBlock: "latest",
    });
    for (const ev of past) {
      const a = (ev as unknown as { args: { _pool: Address } }).args;
      if (a._pool) await subscribePool(a._pool);
    }
  } catch (err) {
    log("warn", "entrypoint pool-registration backfill failed", { err: String(err) });
  }

  publicClient.watchContractEvent({
    address: cfg.entrypoint,
    abi: ENTRYPOINT_ABI,
    eventName: "PoolRegistered",
    onLogs(logs: Log[]) {
      for (const ev of logs) {
        const a = (ev as unknown as { args: { _pool: Address } }).args;
        if (a._pool) void subscribePool(a._pool);
      }
    },
    onError(err: unknown) {
      log("error", "PoolRegistered watch error", { err: String(err) });
    },
  });

  publicClient.watchContractEvent({
    address: cfg.entrypoint,
    abi: ENTRYPOINT_ABI,
    eventName: "PoolRemoved",
    onLogs(logs: Log[]) {
      for (const ev of logs) {
        const a = (ev as unknown as { args: { _pool: Address } }).args;
        // Note: we keep historical labels in the tree even after pool removal,
        // since outstanding shielded balances remain withdrawable.
        log("info", "pool removed (keeping labels in tree)", { pool: a._pool });
      }
    },
  });

  // Periodic flush: publish the current root if anything changed.
  // Re-publishing the same root is wasteful, so skip when !dirty.
  // eslint-disable-next-line no-constant-condition
  while (true) {
    await Bun.sleep(cfg.pollIntervalSeconds * 1000);
    if (!dirty || tree.size === 0) continue;
    const root = tree.root;
    // The Entrypoint validates `32 <= len(cid) <= 64`. Pad to satisfy.
    const cid = `permissive-root-${tree.size}-${Date.now().toString(36)}`.padEnd(32, "x").slice(0, 64);
    log("info", "publishing root", {
      root: `0x${root.toString(16)}`,
      size: tree.size,
      dryRun: cfg.dryRun,
    });
    if (cfg.dryRun) {
      dirty = false;
      continue;
    }
    try {
      const txHash = await walletClient.writeContract({
        chain: null,
        account,
        address: cfg.entrypoint,
        abi: ENTRYPOINT_ABI,
        functionName: "updateRoot",
        args: [root, cid],
      });
      log("info", "updateRoot tx sent", { txHash });
      dirty = false;
    } catch (err) {
      log("error", "updateRoot failed; will retry next tick", { err: String(err) });
    }
  }
}

if (import.meta.main) {
  main().catch((err) => {
    console.error("[asp-postman] fatal:", err);
    process.exit(1);
  });
}
