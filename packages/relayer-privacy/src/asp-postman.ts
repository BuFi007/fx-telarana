// SPDX-License-Identifier: AGPL-3.0-only
//
// Permissive ASP postman — testnet only.
//
// Watches `FxPrivacyEntrypoint.Deposited` events, maintains the in-memory
// label set, and periodically publishes a permissive ASP root via
// `Entrypoint.updateRoot()` so every observed deposit is "approved."
//
// This is the v1 testnet posture documented in
// docs/PRIVACY_HOOK_SPEC.md §5.3 — mainnet replaces this with a real
// screening provider (interface unchanged).

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

/** Minimal ABI surface — we only need Deposited + updateRoot + latestRoot. */
const ENTRYPOINT_ABI = [
  {
    type: "event",
    name: "Deposited",
    inputs: [
      { name: "_depositor", type: "address", indexed: true },
      { name: "_pool", type: "address", indexed: false },
      { name: "_commitment", type: "uint256", indexed: false },
      { name: "_amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "function",
    name: "updateRoot",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_root", type: "uint256" },
      { name: "_ipfsCID", type: "string" },
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

interface PostmanConfig {
  rpcUrl: string;
  privateKey: Hex;
  entrypoint: Address;
  pollIntervalSeconds: number;
  /** If true, do not actually broadcast — just log. */
  dryRun?: boolean;
}

function loadConfig(): PostmanConfig {
  const rpcUrl = Bun.env["RPC_URL"];
  const privateKey = Bun.env["PRIVATE_KEY"] as Hex | undefined;
  const entrypoint = Bun.env["ENTRYPOINT_ADDRESS"] as Address | undefined;
  const pollIntervalSeconds = Number(Bun.env["POLL_INTERVAL_SECONDS"] ?? 30);
  if (!rpcUrl) throw new Error("RPC_URL is required");
  if (!privateKey) throw new Error("PRIVATE_KEY is required");
  if (!entrypoint) throw new Error("ENTRYPOINT_ADDRESS is required");
  return {
    rpcUrl,
    privateKey,
    entrypoint,
    pollIntervalSeconds,
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
    dryRun: cfg.dryRun ?? false,
  });

  // The LeanIMT we publish. Hashes via Poseidon — identical Merkle math
  // to the on-chain InternalLeanIMT in contracts/lib/lean-imt/.
  const tree = new LeanIMT<bigint>((a: bigint, b: bigint) => poseidon([a, b]));
  const observedLabels = new Set<bigint>();
  let dirty = false;

  // Watch new deposits. Each Deposited carries the pool address + commitment.
  // The "label" the user proves against is derived from (scope, nonce) per
  // PrivacyPool.deposit — we observe it indirectly via the pool's
  // `LeafInserted` event. For the skeleton we use commitment as the leaf
  // since both share the SNARK field; slice 4b refines this.
  publicClient.watchContractEvent({
    address: cfg.entrypoint,
    abi: ENTRYPOINT_ABI,
    eventName: "Deposited",
    onLogs(logs: Log[]) {
      for (const ev of logs) {
        const args = (ev as unknown as { args: { _commitment: bigint } }).args;
        if (typeof args._commitment !== "bigint") continue;
        if (observedLabels.has(args._commitment)) continue;
        observedLabels.add(args._commitment);
        tree.insert(args._commitment);
        dirty = true;
        log("info", "leaf added", {
          commitment: `0x${args._commitment.toString(16)}`,
          size: tree.size,
        });
      }
    },
    onError(err: unknown) {
      log("error", "watch error", { err: String(err) });
    },
  });

  // Periodic flush: publish the current root if anything changed.
  // Re-publishing the same root is wasteful, so we skip when !dirty.
  // eslint-disable-next-line no-constant-condition
  while (true) {
    await Bun.sleep(cfg.pollIntervalSeconds * 1000);
    if (!dirty || tree.size === 0) continue;
    const root = tree.root;
    const ipfsCid = `permissive-root-${tree.size}-${Date.now().toString(36).padEnd(8, "0")}`;
    // The Entrypoint validates `32 <= len(cid) <= 64`. Pad if needed.
    const paddedCid = ipfsCid.padEnd(32, "x").slice(0, 64);
    log("info", "publishing root", {
      root: `0x${root.toString(16)}`,
      size: tree.size,
      dryRun: cfg.dryRun ?? false,
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
        args: [root, paddedCid],
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
