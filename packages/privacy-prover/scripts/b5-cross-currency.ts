// SPDX-License-Identifier: GPL-3.0
//
// B5c — Live Arc cross-currency withdraw. Reads the deposit state from
// b5-deposit, reconstructs the pool's on-chain state tree by replaying
// `LeafInserted` events, publishes a fresh ASP root that approves the
// deposit's label, generates a Groth16 withdrawal proof bound to a
// CrossCurrencyRelayData (buyToken = EURC), then calls
// FxPrivacyEntrypoint.relayCrossCurrency() — which atomically:
//
//   1. Withdraws sellAmount from the pool to entrypoint.
//   2. Forwards sellAmount to FxFixedRateSwapAdapter.
//   3. Adapter swaps USDC → EURC at the owner-set rate.
//   4. Entrypoint measures the buy-side delta + forwards EURC to the
//      user's signed recipient.
//
// End state: a brand-new address holds EURC, with no on-chain link to
// the USDC depositor. This is the marquee privacy feature.
//
// Pre-req: b5-deposit must have just run (state file written) and the
// adapter must be funded with ≥ minBuyAmount of EURC.

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  encodeAbiParameters,
  http,
  parseAbi,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";

import * as snarkjs from "snarkjs";

import {
  bigintToHash,
  calculateContext,
  generateMerkleProof,
  type Secret,
  type Withdrawal,
} from "@bu/fx-engine/privacy";

const __dirname = dirname(fileURLToPath(import.meta.url));

const ARC_RPC      = "https://rpc.testnet.arc.network";
const ARC_CHAIN_ID = 5042002;
const EURC: Address = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

const t0 = Date.now();
const log = (msg: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(2)}s] ${msg}`);

// ---- Load deposit state ----
const statePath = join(__dirname, ".b5-deposit-state.json");
if (!existsSync(statePath)) {
  console.error(`Deposit state not found at ${statePath}. Run b5-deposit first.`);
  process.exit(1);
}
const state = JSON.parse(readFileSync(statePath, "utf-8"));
log(`loaded deposit state, value=${state.value}, label=${state.label}`);

const nullifier = BigInt(state.nullifier) as Secret;
const secret    = BigInt(state.secret) as Secret;
const value     = BigInt(state.value);
const label     = BigInt(state.label);
const commitmentHash = BigInt(state.commitmentHash);
const depositBlock = BigInt(state.depositBlock);

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
const chain = {
  id: ARC_CHAIN_ID, name: "arc-testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [ARC_RPC] } },
} as const;
const publicClient: PublicClient = createPublicClient({ chain, transport: http(ARC_RPC) });
const walletClient = createWalletClient({ account, chain, transport: http(ARC_RPC) });

// ---- ABIs ----
const ENTRYPOINT_ABI = parseAbi([
  "function updateRoot(uint256 root, string ipfsCID) returns (uint256 index)",
  "function latestRoot() view returns (uint256)",
  "function relayCrossCurrency((address processooor, bytes data) withdrawal, (uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[8] pubSignals) proof, uint256 scope)",
]);
const POOL_ABI = parseAbi([
  "function SCOPE() view returns (uint256)",
  "function currentRoot() view returns (uint256)",
  "event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root)",
]);
const ERC20_ABI = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
]);

// ---- Reconstruct pool state tree from LeafInserted events ----
//
// The on-chain tree is append-only (LeanIMT). We replay the events to
// rebuild a local tree whose root matches `pool.currentRoot()`. The
// circuit's stateRoot public signal must equal the on-chain root for
// the inclusion check to pass.
log("scanning LeafInserted events to reconstruct state tree");
const head = await publicClient.getBlockNumber();
// Fuji-style pagination — Arc accepts 5000 per call, but the live tree
// is small so a single 50000-block window is fine here.
const PAGE = 5000n;
// Pool was deployed at block 43028530 (see deployments/privacy-hook-arc.json).
// Start a bit before to be safe; replay covers all historical inserts.
const POOL_DEPLOY_BLOCK = 43028000n;
let cursor = POOL_DEPLOY_BLOCK;
log(`replaying from block ${cursor} to head ${head} (depositBlock=${depositBlock})`);
const leaves: bigint[] = [];
while (cursor <= head) {
  const end = cursor + PAGE - 1n > head ? head : cursor + PAGE - 1n;
  const logs = await publicClient.getContractEvents({
    address: pool,
    abi: POOL_ABI,
    eventName: "LeafInserted",
    fromBlock: cursor,
    toBlock: end,
  });
  // viem already filters by abi event name; just append leaves in order.
  for (const ev of logs) {
    const args = ev.args as { _index?: bigint; _leaf?: bigint };
    if (typeof args._leaf === "bigint") leaves.push(args._leaf);
  }
  cursor = end + 1n;
}
log(`replayed ${leaves.length} leaves: [${leaves.slice(0, 3).join(", ")}${leaves.length > 3 ? ", …" : ""}]`);

const ourIndex = leaves.findIndex((l) => l === commitmentHash);
if (ourIndex === -1) {
  console.error(`commitment hash ${commitmentHash} not found in pool's leaf set`);
  process.exit(1);
}
log(`our commitment is leaf #${ourIndex}`);

const stateMerkleProof = generateMerkleProof(leaves, commitmentHash);
log(`state root (local) = ${stateMerkleProof.root}`);

const stateRootOnChain = await publicClient.readContract({
  address: pool, abi: POOL_ABI, functionName: "currentRoot",
}) as bigint;
log(`state root (chain) = ${stateRootOnChain}`);
if (stateRootOnChain !== stateMerkleProof.root) {
  console.error("state root mismatch — local replay diverged from chain");
  process.exit(1);
}
log("state root matches on-chain ✓");

// ---- Publish ASP root (single-leaf w/ our label) ----
const aspRoot = label;
const cid = `permissive-root-${Date.now().toString(36)}`.padEnd(40, "x");
log(`publishing ASP root ${aspRoot}`);
const updateRootHash = await walletClient.writeContract({
  address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "updateRoot",
  args: [aspRoot, cid],
});
await publicClient.waitForTransactionReceipt({ hash: updateRootHash });
const latest = await publicClient.readContract({
  address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "latestRoot",
}) as bigint;
if (latest !== aspRoot) {
  console.error(`latestRoot drift: chain=${latest} local=${aspRoot}`);
  process.exit(1);
}
log("ASP root confirmed ✓");

const aspMerkleProof = generateMerkleProof([label], label);

// ---- Build CrossCurrencyRelayData ----
const recipientKey = generatePrivateKey();
const recipient = privateKeyToAccount(recipientKey).address;
log(`recipient (fresh address) = ${recipient}`);

// Rate is 0.92 (USDC→EURC); 1 USDC → 0.92 EURC = 920000. Use 0.9 EURC
// (900000) as the user-signed lower bound (~2% slippage tolerance).
const minBuyAmount = 900_000n;
const relayFeeBPS = 0n;
const feeRecipient = account.address;

const crossData = encodeAbiParameters(
  [
    { type: "address", name: "recipient" },
    { type: "address", name: "feeRecipient" },
    { type: "uint256", name: "relayFeeBPS" },
    { type: "address", name: "buyToken" },
    { type: "uint256", name: "minBuyAmount" },
  ],
  [recipient, feeRecipient, relayFeeBPS, EURC, minBuyAmount],
);
const withdrawal: Withdrawal = { processooor: entrypoint, data: crossData };

const scope = await publicClient.readContract({
  address: pool, abi: POOL_ABI, functionName: "SCOPE",
}) as bigint;
const contextHex = calculateContext(withdrawal, bigintToHash(scope));
const context = BigInt(contextHex);
log(`scope = ${scope}, context = ${context}`);

// ---- Generate proof ----
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

const wasm = new Uint8Array(readFileSync(join(__dirname, "..", "circuits", "withdraw.wasm")));
const zkey = new Uint8Array(readFileSync(join(__dirname, "..", "circuits", "withdraw.zkey")));
log("calling snarkjs.groth16.fullProve");
const { proof, publicSignals } = await snarkjs.groth16.fullProve(inputSignals, wasm, zkey);
log(`fullProve done — publicSignals.length=${(publicSignals as string[]).length}`);

const pA: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
const pB: [[bigint, bigint], [bigint, bigint]] = [
  [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
  [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
];
const pC: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];
const sig = publicSignals as string[];
if (sig.length !== 8) { console.error(`publicSignals length ${sig.length}`); process.exit(1); }
const pubSignals = sig.map((s) => BigInt(s)) as unknown as [
  bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint,
];

// ---- Pre-balance ----
const recipEurcBefore = await publicClient.readContract({
  address: EURC, abi: ERC20_ABI, functionName: "balanceOf", args: [recipient],
}) as bigint;
log(`recipient EURC balance before = ${recipEurcBefore}`);

// ---- Call relayCrossCurrency ----
log("calling entrypoint.relayCrossCurrency");
const relayHash = await walletClient.writeContract({
  address: entrypoint,
  abi: ENTRYPOINT_ABI,
  functionName: "relayCrossCurrency",
  args: [withdrawal, { pA, pB, pC, pubSignals }, scope],
});
log(`relayCrossCurrency tx ${relayHash}`);
const receipt = await publicClient.waitForTransactionReceipt({ hash: relayHash });
log(`relayCrossCurrency confirmed in block ${receipt.blockNumber}, status=${receipt.status}`);

const recipEurcAfter = await publicClient.readContract({
  address: EURC, abi: ERC20_ABI, functionName: "balanceOf", args: [recipient],
}) as bigint;
log(`recipient EURC balance after  = ${recipEurcAfter}`);
const delta = recipEurcAfter - recipEurcBefore;
log(`delta = ${delta} (expected ≥ ${minBuyAmount})`);
if (delta < minBuyAmount) {
  console.error(`delta below minBuyAmount`);
  process.exit(1);
}

log(`B5c ✅ CROSS-CURRENCY shielded USDC → EURC, delivered ${delta} EURC to fresh address`);
process.exit(0);
