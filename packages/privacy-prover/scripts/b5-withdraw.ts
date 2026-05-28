// SPDX-License-Identifier: GPL-3.0
//
// B5b — Live Arc same-currency withdraw. Reads the deposit state from
// b5-deposit, publishes an ASP root that approves the deposit's label,
// generates the Groth16 withdrawal proof, then calls
// FxPrivacyEntrypoint.relay() to deliver USDC to a fresh recipient.
//
//   1. Load .b5-deposit-state.json (nullifier, secret, label, commitment,
//      value, addresses).
//   2. Publish ASP root via entrypoint.updateRoot(label, cid) so the
//      circuit's ASPRoot inclusion check passes.
//   3. Build the local state tree (single leaf = commitmentHash) +
//      single-leaf ASP tree.
//   4. Compute context for a same-currency relay (RelayData with a
//      freshly-derived recipient).
//   5. proveWithdrawal via @bu/privacy-prover.
//   6. Submit relay(withdrawal, proof, scope) to entrypoint.
//   7. Assert recipient USDC balance ≈ withdrawnValue.
//
// Usage:
//   DEPLOYER_PRIVATE_KEY=0x... bun build scripts/b5-withdraw.ts --target node \
//     --outfile dist/b5-withdraw.mjs --external snarkjs && \
//   node dist/b5-withdraw.mjs

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { generatePrivateKey } from "viem/accounts";

import * as snarkjs from "snarkjs";

import {
  CircuitName,
  bigintToHash,
  calculateContext,
  generateMerkleProof,
  getCommitment,
  type CircuitsInterface,
  type Secret,
  type Withdrawal,
} from "@bu/fx-engine/privacy";

const __dirname = dirname(fileURLToPath(import.meta.url));

const ARC_RPC      = "https://rpc.drpc.testnet.arc.network";
const ARC_CHAIN_ID = 5042002;

const t0 = Date.now();
const log = (msg: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(2)}s] ${msg}`);

// ---- Load deposit state ----
// b5-deposit writes to (build-output)/.b5-deposit-state.json. The
// build-output for THIS script also lives in dist/ so __dirname matches.
const statePath = join(__dirname, ".b5-deposit-state.json");
if (!existsSync(statePath)) {
  console.error(`Deposit state not found at ${statePath}. Run b5-deposit first.`);
  process.exit(1);
}
const state = JSON.parse(readFileSync(statePath, "utf-8"));
log(`loaded deposit state from ${statePath}`);
log(`  pool = ${state.pool}`);
log(`  entrypoint = ${state.entrypoint}`);
log(`  value = ${state.value}`);
log(`  label = ${state.label}`);

const nullifier = BigInt(state.nullifier) as Secret;
const secret    = BigInt(state.secret) as Secret;
const value     = BigInt(state.value);
const label     = BigInt(state.label);
const commitmentHash = BigInt(state.commitmentHash);

const pool: Address       = state.pool;
const entrypoint: Address = state.entrypoint;
const asset: Address      = state.asset;

// ---- Chain client setup ----
const pk = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined;
if (!pk) {
  console.error("DEPLOYER_PRIVATE_KEY is required");
  process.exit(1);
}
const account = privateKeyToAccount(pk);
log(`deployer = ${account.address}`);

const chain = {
  id: ARC_CHAIN_ID, name: "arc-testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [ARC_RPC] } },
} as const;
const publicClient = createPublicClient({ chain, transport: http(ARC_RPC) });
const walletClient = createWalletClient({ account, chain, transport: http(ARC_RPC) });

// ---- ABIs ----
const ENTRYPOINT_ABI = parseAbi([
  "function updateRoot(uint256 root, string ipfsCID) returns (uint256 index)",
  "function latestRoot() view returns (uint256)",
  "function relay((address processooor, bytes data) withdrawal, (uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[8] pubSignals) proof, uint256 scope)",
]);
const POOL_ABI = parseAbi([
  "function SCOPE() view returns (uint256)",
]);
const ERC20_ABI = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
]);

// ---- Publish ASP root ----
//
// Single-leaf tree → root == leaf value == label. The pool's withdraw
// will gate against this published root via the Groth16 circuit's
// ASPRoot inclusion check. Single-writer constraint applies: only one
// updateRoot in flight at a time (we are the sole writer here, deployer
// holding the ASP_POSTMAN role per C2b deferred-rotation).
const aspRoot = label;
const cid = `permissive-root-${Date.now().toString(36)}`.padEnd(40, "x");
log(`publishing ASP root ${aspRoot} (cid='${cid}')`);
const updateRootHash = await walletClient.writeContract({
  address: entrypoint,
  abi: ENTRYPOINT_ABI,
  functionName: "updateRoot",
  args: [aspRoot, cid],
});
log(`updateRoot tx ${updateRootHash}`);
await publicClient.waitForTransactionReceipt({ hash: updateRootHash });
const onchainRoot = await publicClient.readContract({
  address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "latestRoot",
});
log(`entrypoint.latestRoot() = ${onchainRoot}`);
if (onchainRoot !== aspRoot) {
  console.error(`latestRoot mismatch: chain=${onchainRoot} local=${aspRoot}`);
  process.exit(1);
}
log("ASP root confirmed on-chain ✓");

// ---- Build local trees (state + ASP, each 1 leaf) ----
const stateMerkleProof = generateMerkleProof([commitmentHash], commitmentHash);
const aspMerkleProof   = generateMerkleProof([label], label);
log(`state root = ${stateMerkleProof.root} (siblings.length=${stateMerkleProof.siblings.length})`);
log(`asp   root = ${aspMerkleProof.root}`);

// ---- Build withdrawal + context ----
// Fresh recipient — a random key, just so the destination address has no
// prior history.
const recipientKey = generatePrivateKey();
const recipient = privateKeyToAccount(recipientKey).address;
log(`recipient (fresh address) = ${recipient}`);

const relayFeeBPS = 0n;
const feeRecipient = account.address; // dev — would be relayer EOA in prod

// RelayData ABI: tuple(address recipient, address feeRecipient, uint256 relayFeeBPS)
const relayData = encodeAbiParameters(
  [
    { type: "address", name: "recipient" },
    { type: "address", name: "feeRecipient" },
    { type: "uint256", name: "relayFeeBPS" },
  ],
  [recipient, feeRecipient, relayFeeBPS],
);
const withdrawal: Withdrawal = { processooor: entrypoint, data: relayData };

// Read scope from pool
const scope = await publicClient.readContract({
  address: pool, abi: POOL_ABI, functionName: "SCOPE",
}) as bigint;
log(`pool.SCOPE() = ${scope}`);
const scopeAsHash = bigintToHash(scope);
const contextHex = calculateContext(withdrawal, scopeAsHash);
const context = BigInt(contextHex);
log(`context = ${context}`);

// ---- Generate Groth16 proof ----
// Fresh post-withdraw secrets so the spent note has a replacement note.
function randomFieldElement(): bigint {
  const buf = new Uint8Array(31);
  crypto.getRandomValues(buf);
  let v = 0n;
  for (const b of buf) v = (v << 8n) | BigInt(b);
  return v;
}
const newNullifier = randomFieldElement() as Secret;
const newSecret    = randomFieldElement() as Secret;

const inputSignals = {
  withdrawnValue: value,
  stateRoot: stateMerkleProof.root,
  stateTreeDepth: BigInt(stateMerkleProof.siblings.length),
  ASPRoot: aspMerkleProof.root,
  ASPTreeDepth: BigInt(aspMerkleProof.siblings.length),
  context,
  label,
  existingValue: value,
  existingNullifier: nullifier,
  existingSecret: secret,
  newNullifier,
  newSecret,
  stateSiblings: stateMerkleProof.siblings,
  stateIndex: BigInt(stateMerkleProof.index),
  ASPSiblings: aspMerkleProof.siblings,
  ASPIndex: BigInt(aspMerkleProof.index),
};

const wasmPath = join(__dirname, "..", "circuits", "withdraw.wasm");
const zkeyPath = join(__dirname, "..", "circuits", "withdraw.zkey");
const wasmBytes = new Uint8Array(readFileSync(wasmPath));
const zkeyBytes = new Uint8Array(readFileSync(zkeyPath));

log("calling snarkjs.groth16.fullProve");
const { proof, publicSignals } = await snarkjs.groth16.fullProve(
  inputSignals, wasmBytes, zkeyBytes,
);
log(`fullProve done — publicSignals.length=${(publicSignals as string[]).length}`);

// ---- Reshape proof for Solidity ----
// FxPrivacyEntrypoint.relay expects WithdrawProof = {
//   uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[8] pubSignals
// }. The vendored ProofLib lays out pubSignals in a specific order;
// the circuit emits them as the public-signal output array directly.
// pi_b inner pairs need to be reversed for BN254 curve element pairing.
const pA: [bigint, bigint] = [
  BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1]),
];
const pB: [[bigint, bigint], [bigint, bigint]] = [
  [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
  [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
];
const pC: [bigint, bigint] = [
  BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1]),
];
const sig = publicSignals as string[];
if (sig.length !== 8) {
  console.error(`unexpected publicSignals length ${sig.length}, want 8`);
  process.exit(1);
}
const pubSignals = sig.map((s) => BigInt(s)) as unknown as [
  bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint,
];
log("proof reshaped for Solidity calldata");

// ---- Recipient pre-balance ----
const recipBalanceBefore = await publicClient.readContract({
  address: asset, abi: ERC20_ABI, functionName: "balanceOf", args: [recipient],
}) as bigint;
log(`recipient USDC balance before = ${recipBalanceBefore}`);

// ---- Call entrypoint.relay ----
log("calling entrypoint.relay");
const relayHash = await walletClient.writeContract({
  address: entrypoint,
  abi: ENTRYPOINT_ABI,
  functionName: "relay",
  args: [
    withdrawal,
    { pA, pB, pC, pubSignals },
    scope,
  ],
});
log(`relay tx ${relayHash}`);
const relayReceipt = await publicClient.waitForTransactionReceipt({ hash: relayHash });
log(`relay confirmed in block ${relayReceipt.blockNumber}, status=${relayReceipt.status}`);

const recipBalanceAfter = await publicClient.readContract({
  address: asset, abi: ERC20_ABI, functionName: "balanceOf", args: [recipient],
}) as bigint;
log(`recipient USDC balance after  = ${recipBalanceAfter}`);
const delta = recipBalanceAfter - recipBalanceBefore;
log(`delta = ${delta} (expected ${value})`);
if (delta !== value) {
  console.error(`delta mismatch — expected ${value}, got ${delta}`);
  process.exit(1);
}
log("B5b ✅ shielded USDC withdrawn to fresh address");
process.exit(0);
