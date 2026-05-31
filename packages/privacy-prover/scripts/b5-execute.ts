// SPDX-License-Identifier: GPL-3.0
//
// B5e — Live Arc PRIVATE EXECUTION round-trip (own-stack executor). Thin
// orchestration over @bu/privacy-prover's proveAndBuildRelayExecute engine:
// load the deposit note, publish the ASP root, prove, submit relayExecute.
// Proven live-green (Morpho supply from a shielded note). See relay-execute.ts.
//
// Env: DEPLOYER_PRIVATE_KEY, EXEC_ADAPTER_ID (default 1), EXEC_ADAPTER_DATA (hex).
// Build/run: bun build scripts/b5-execute.ts --target node --outfile dist/b5-execute.mjs \
//   --external snarkjs && node dist/b5-execute.mjs

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createPublicClient, createWalletClient, http, parseAbi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { proveAndBuildRelayExecute, type ShieldedNote } from "../src/index.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARC_RPC = "https://rpc.drpc.testnet.arc.network";
const ARC_CHAIN_ID = 5042002;
const t0 = Date.now();
const log = (m: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(2)}s] ${m}`);

const statePath = join(__dirname, ".b5-deposit-state.json");
if (!existsSync(statePath)) { console.error(`Deposit state not found at ${statePath}. Run b5-deposit first.`); process.exit(1); }
const state = JSON.parse(readFileSync(statePath, "utf-8"));
const note: ShieldedNote = {
  nullifier: BigInt(state.nullifier), secret: BigInt(state.secret), value: BigInt(state.value),
  label: BigInt(state.label), commitmentHash: BigInt(state.commitmentHash),
};
const pool: Address = state.pool;
const entrypoint: Address = state.entrypoint;

const pk = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined;
if (!pk) { console.error("DEPLOYER_PRIVATE_KEY required"); process.exit(1); }
const account = privateKeyToAccount(pk);
const adapterId = BigInt(process.env.EXEC_ADAPTER_ID ?? "1");
const adapterData = (process.env.EXEC_ADAPTER_DATA ?? "0x") as Hex;

const chain = { id: ARC_CHAIN_ID, name: "arc-testnet", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [ARC_RPC] } } } as const;
const publicClient = createPublicClient({ chain, transport: http(ARC_RPC) });
const walletClient = createWalletClient({ account, chain, transport: http(ARC_RPC) });

const ENTRYPOINT_ABI = parseAbi([
  "function updateRoot(uint256 root, string ipfsCID) returns (uint256 index)",
  "function latestRoot() view returns (uint256)",
  "function relayExecute((address processooor, bytes data) withdrawal, (uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[8] pubSignals) proof, uint256 scope)",
]);

// Publish ASP root (single-leaf == label), idempotent.
const cur = (await publicClient.readContract({ address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "latestRoot" })) as bigint;
if (cur === note.label) {
  log(`ASP root ${note.label} already published`);
} else {
  const ur = await walletClient.writeContract({ address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "updateRoot", args: [note.label, `permissive-${Date.now().toString(36)}`.padEnd(40, "x")] });
  await publicClient.waitForTransactionReceipt({ hash: ur });
  log("ASP root published");
}

log("proveAndBuildRelayExecute …");
const { withdrawal, proof, scope, stateRoot, leafCount } = await proveAndBuildRelayExecute({
  publicClient, pool, entrypoint, note,
  adapterId, adapterData, recipient: account.address, feeRecipient: account.address, relayFeeBPS: 0n,
  aspRoot: note.label,
  wasmBytes: new Uint8Array(readFileSync(join(__dirname, "..", "circuits", "withdraw.wasm"))),
  zkeyBytes: new Uint8Array(readFileSync(join(__dirname, "..", "circuits", "withdraw.zkey"))),
});
log(`proof built; stateRoot=${stateRoot} leaves=${leafCount}`);

log("submitting relayExecute …");
const tx = await walletClient.writeContract({ address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "relayExecute", args: [withdrawal, proof, scope] });
const r = await publicClient.waitForTransactionReceipt({ hash: tx });
log(`relayExecute block ${r.blockNumber} status=${r.status} tx=${tx}`);
if (r.status !== "success") { console.error("relayExecute reverted"); process.exit(1); }
log("B5e ✅ private execution from shielded note (relayExecute) landed on Arc");
process.exit(0);
