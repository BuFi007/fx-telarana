// SPDX-License-Identifier: GPL-3.0
//
// B5e — Live Arc PRIVATE EXECUTION round-trip for the own-stack executor.
// Identical proving path to b5-withdraw (same withdraw circuit, same deployed
// WithdrawalVerifier — NO new circuit), but the withdrawal.data carries an
// ExecutionRelayData blob and we submit FxPrivacyEntrypoint.relayExecute(), which
// withdraws the shielded note and atomically runs a REGISTERED execution adapter
// (e.g. Morpho supply) funded from it. The adapter + calldata are bound into the
// proof context (keccak256(withdrawal, scope)), so a relayer cannot redirect.
//
//   1. Load .b5-deposit-state.json (nullifier, secret, label, commitment, value).
//   2. Publish ASP root (updateRoot) so the circuit's ASPRoot check passes.
//   3. Build single-leaf state + ASP trees; compute context over the EXECUTION
//      withdrawal blob.
//   4. snarkjs.groth16.fullProve (withdraw.wasm/.zkey).
//   5. Submit relayExecute(withdrawal, proof, scope).
//   6. Assert the action landed (Executed event / target state).
//
// Env: DEPLOYER_PRIVATE_KEY, optional EXEC_ADAPTER_ID (default 1),
//      EXEC_ADAPTER_DATA (hex; e.g. abi-encoded Morpho MarketParams).
//
// Build/run like b5-withdraw:
//   bun build scripts/b5-execute.ts --target node --outfile dist/b5-execute.mjs \
//     --external snarkjs && node dist/b5-execute.mjs

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  encodeFunctionData,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import * as snarkjs from "snarkjs";

import {
  bigintToHash,
  calculateContext,
  generateMerkleProof,
  type Secret,
  type Withdrawal,
} from "@bu/fx-engine/privacy";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARC_RPC = "https://rpc.drpc.testnet.arc.network";
const ARC_CHAIN_ID = 5042002;
const t0 = Date.now();
const log = (m: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(2)}s] ${m}`);

const statePath = join(__dirname, ".b5-deposit-state.json");
if (!existsSync(statePath)) {
  console.error(`Deposit state not found at ${statePath}. Run b5-deposit first.`);
  process.exit(1);
}
const state = JSON.parse(readFileSync(statePath, "utf-8"));
const nullifier = BigInt(state.nullifier) as Secret;
const secret = BigInt(state.secret) as Secret;
const value = BigInt(state.value);
const label = BigInt(state.label);
const commitmentHash = BigInt(state.commitmentHash);
const pool: Address = state.pool;
const entrypoint: Address = state.entrypoint;

const pk = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined;
if (!pk) { console.error("DEPLOYER_PRIVATE_KEY required"); process.exit(1); }
const account = privateKeyToAccount(pk);
log(`deployer = ${account.address}`);

// adapterId of the registered execution adapter, + its calldata (e.g. Morpho
// MarketParams). Default to id 1 (the convention used in the registry tests).
const adapterId = BigInt(process.env.EXEC_ADAPTER_ID ?? "1");
const adapterData = (process.env.EXEC_ADAPTER_DATA ?? "0x") as Hex;

const chain = {
  id: ARC_CHAIN_ID, name: "arc-testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [ARC_RPC] } },
} as const;
const publicClient = createPublicClient({ chain, transport: http(ARC_RPC) });
const walletClient = createWalletClient({ account, chain, transport: http(ARC_RPC) });

const ENTRYPOINT_ABI = parseAbi([
  "function updateRoot(uint256 root, string ipfsCID) returns (uint256 index)",
  "function latestRoot() view returns (uint256)",
  "function relayExecute((address processooor, bytes data) withdrawal, (uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[8] pubSignals) proof, uint256 scope)",
]);
const POOL_ABI = parseAbi(["function SCOPE() view returns (uint256)"]);

// ASP root (single-leaf == label). Idempotent: re-inserting the same ASP leaf
// reverts (LeanIMT rejects duplicates), so skip if already the latest root.
const aspRoot = label;
const curRoot = await publicClient.readContract({ address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "latestRoot" }) as bigint;
if (curRoot === aspRoot) {
  log(`ASP root ${aspRoot} already published — skipping updateRoot`);
} else {
  const cid = `permissive-root-${Date.now().toString(36)}`.padEnd(40, "x");
  log(`publishing ASP root ${aspRoot}`);
  const ur = await walletClient.writeContract({ address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "updateRoot", args: [aspRoot, cid] });
  await publicClient.waitForTransactionReceipt({ hash: ur });
  log("ASP root confirmed");
}

// Reconstruct the pool's REAL state tree from on-chain Deposited events — the
// pool has multiple leaves, so a synthetic single-leaf root is unknown to it
// (pool.withdraw's _isKnownRoot would revert). ASP tree stays single-leaf (we
// publish our label as latestRoot above).
// Reconstruct from LeafInserted (every state-tree insert: deposits AND
// withdrawal change-notes), NOT Deposited — the tree grows on withdrawals too.
const POOL_DEPOSIT_ABI = parseAbi([
  "event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root)",
]);
// The free-tier RPC caps eth_getLogs at 10k blocks but DOES serve historical
// eth_call. So binary-search `currentTreeSize()` by block to find each leaf's
// insertion block, then a 1-block getLogs per block. O(treeSize · log range).
const SIZE_ABI = parseAbi(["function currentTreeSize() view returns (uint256)"]);
const treeSize = Number(await publicClient.readContract({ address: pool, abi: SIZE_ABI, functionName: "currentTreeSize" }) as bigint);
const latest = await publicClient.getBlockNumber();
const sizeAt = async (block: bigint): Promise<number> => {
  try { return Number(await publicClient.readContract({ address: pool, abi: SIZE_ABI, functionName: "currentTreeSize", blockNumber: block }) as bigint); }
  catch { return 0; } // pre-deploy / no code → 0 leaves
};
// smallest block whose tree size >= s
const blockForSize = async (s: number): Promise<bigint> => {
  let lo = 40_000_000n, hi = latest, ans = hi;
  while (lo <= hi) {
    const mid = (lo + hi) / 2n;
    if ((await sizeAt(mid)) >= s) { ans = mid; hi = mid - 1n; } else { lo = mid + 1n; }
  }
  return ans;
};
const blocks = new Set<bigint>();
for (let s = 1; s <= treeSize; s++) blocks.add(await blockForSize(s));
log(`leaf-insertion blocks: ${[...blocks].map(String).join(", ")}`);
const seen = new Set<string>();
const collected: any[] = [];
for (const b of blocks) {
  // small window catches off-by-one between size-transition block and the tx
  const lo = b > 8n ? b - 8n : 0n;
  const chunk = await publicClient.getLogs({ address: pool, event: POOL_DEPOSIT_ABI[0], fromBlock: lo, toBlock: b + 8n });
  for (const l of chunk) {
    const k = `${l.transactionHash}:${l.logIndex}`;
    if (!seen.has(k)) { seen.add(k); collected.push(l); }
  }
}
log(`collected ${collected.length}/${treeSize} LeafInserted logs`);
const leaves = collected
  .sort((a, b) => Number((a.args as { _index: bigint })._index - (b.args as { _index: bigint })._index))
  .map((l) => (l.args as { _leaf: bigint })._leaf);
log(`fetched ${leaves.length} pool leaves; my leaf index = ${leaves.findIndex((c) => c === commitmentHash)}`);
const stateMP = generateMerkleProof(leaves, commitmentHash);
const onchainRootNow = await publicClient.readContract({ address: pool, abi: parseAbi(["function currentRoot() view returns (uint256)"]), functionName: "currentRoot" }) as bigint;
if (stateMP.root !== onchainRootNow) {
  console.error(`reconstructed state root ${stateMP.root} != pool.currentRoot() ${onchainRootNow}`);
  process.exit(1);
}
log(`state root matches pool.currentRoot() ✓ (${stateMP.root})`);
const aspMP = generateMerkleProof([label], label);

const recipient = account.address; // executor / onBehalf — detached in prod
const feeRecipient = account.address;
const relayFeeBPS = 0n;

// ExecutionRelayData is a struct with a DYNAMIC `bytes` field, so the entrypoint's
// abi.decode(data, (ExecutionRelayData)) expects a SINGLE dynamic TUPLE (leading
// offset), NOT 5 separate head params. Encode as one tuple type to match.
const executionData = encodeAbiParameters(
  [
    {
      type: "tuple",
      name: "d",
      components: [
        { type: "uint256", name: "adapterId" },
        { type: "address", name: "recipient" },
        { type: "address", name: "feeRecipient" },
        { type: "uint256", name: "relayFeeBPS" },
        { type: "bytes", name: "data" },
      ],
    },
  ],
  [{ adapterId, recipient, feeRecipient, relayFeeBPS, data: adapterData }],
);
const withdrawal: Withdrawal = { processooor: entrypoint, data: executionData };

const scope = await publicClient.readContract({ address: pool, abi: POOL_ABI, functionName: "SCOPE" }) as bigint;
const context = BigInt(calculateContext(withdrawal, bigintToHash(scope)));
log(`context (binds ExecutionRelayData) = ${context}`);

function rfe(): bigint { const b = new Uint8Array(31); crypto.getRandomValues(b); let v = 0n; for (const x of b) v = (v << 8n) | BigInt(x); return v; }
const inputSignals = {
  withdrawnValue: value, stateRoot: stateMP.root, stateTreeDepth: BigInt(stateMP.siblings.length),
  ASPRoot: aspMP.root, ASPTreeDepth: BigInt(aspMP.siblings.length), context, label,
  existingValue: value, existingNullifier: nullifier, existingSecret: secret,
  newNullifier: rfe() as Secret, newSecret: rfe() as Secret,
  stateSiblings: stateMP.siblings, stateIndex: BigInt(stateMP.index),
  ASPSiblings: aspMP.siblings, ASPIndex: BigInt(aspMP.index),
};

const wasmBytes = new Uint8Array(readFileSync(join(__dirname, "..", "circuits", "withdraw.wasm")));
const zkeyBytes = new Uint8Array(readFileSync(join(__dirname, "..", "circuits", "withdraw.zkey")));
log("snarkjs.groth16.fullProve …");
const { proof, publicSignals } = await snarkjs.groth16.fullProve(inputSignals, wasmBytes, zkeyBytes);
const sig = publicSignals as string[];
if (sig.length !== 8) { console.error(`publicSignals length ${sig.length} != 8`); process.exit(1); }

const pA: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
const pB: [[bigint, bigint], [bigint, bigint]] = [
  [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
  [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
];
const pC: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];
const pubSignals = sig.map((s) => BigInt(s)) as unknown as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];

// Dump exact args for a forge fork-trace replay.
{
  const { writeFileSync } = await import("node:fs");
  writeFileSync(join(__dirname, ".b5-execute-args.json"), JSON.stringify({
    withdrawalData: withdrawal.data, processooor: withdrawal.processooor,
    pA: pA.map(String), pB: pB.map((r) => r.map(String)), pC: pC.map(String),
    pubSignals: (pubSignals as bigint[]).map(String), scope: scope.toString(),
  }, null, 2));
  log("dumped args → .b5-execute-args.json");
}

console.log("CALLDATA_HEX=" + encodeFunctionData({ abi: ENTRYPOINT_ABI, functionName: "relayExecute", args: [withdrawal, { pA, pB, pC, pubSignals }, scope] }));

log("calling entrypoint.relayExecute");
const tx = await walletClient.writeContract({
  address: entrypoint, abi: ENTRYPOINT_ABI, functionName: "relayExecute",
  args: [withdrawal, { pA, pB, pC, pubSignals }, scope],
});
const r = await publicClient.waitForTransactionReceipt({ hash: tx });
log(`relayExecute confirmed block ${r.blockNumber} status=${r.status} tx=${tx}`);
if (r.status !== "success") { console.error("relayExecute reverted"); process.exit(1); }
log("B5e ✅ private execution from shielded note (relayExecute) landed on Arc");
process.exit(0);
