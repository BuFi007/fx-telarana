// SPDX-License-Identifier: GPL-3.0
//
// B5a — Live Arc deposit smoke. Shields 1 USDC into the live
// FxPrivacyPool(USDC) via FxPrivacyEntrypoint.deposit(), then prints
// the resulting commitment + label so b5-withdraw can pick it up.
//
//   1. Generate fresh (nullifier, secret); compute precommitment.
//   2. Approve USDC → entrypoint for the deposit value.
//   3. Call entrypoint.deposit(USDC, value, precommitment).
//   4. Parse the Deposited event from the pool to recover the label
//      the privacy pool assigned to this commitment.
//   5. Persist the full secret bundle to disk
//      (scripts/.b5-deposit-state.json) so b5-withdraw runs against
//      the exact same note.
//
// Usage:
//   DEPLOYER_PRIVATE_KEY=0x... bun run scripts/b5-deposit.ts
//
// Outputs:
//   stdout — pipeline timing + the Deposited event values.
//   ./scripts/.b5-deposit-state.json — { nullifier, secret, value,
//   label, commitmentHash, blockNumber, txHash }.

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  encodeFunctionData,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  bigintToHash,
  getCommitment,
  type Secret,
} from "@bu/fx-engine/privacy";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---- Constants — live Arc Testnet ----
const ARC_RPC      = "https://rpc.testnet.arc.network";
const ARC_CHAIN_ID = 5042002;
const USDC         = "0x3600000000000000000000000000000000000000" as const;
const ENTRYPOINT   = "0xD11cDdd1f04e850d3810a71608A49907c80f2736" as const;
const POOL_USDC    = "0xC11C216C9C7A36848b1d4276d223160C8b51988f" as const;
const DEPOSIT_AMOUNT = 1_000_000n; // 1 USDC (6 decimals)

const t0 = Date.now();
const log = (msg: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(2)}s] ${msg}`);

// crypto.subtle is available in node 22+; we just need 32 random bytes
// that fit inside BN254's scalar field (so anything < 2^252 is safe).
function randomFieldElement(): bigint {
  const buf = new Uint8Array(31); // 248 bits — comfortably under 2^252
  crypto.getRandomValues(buf);
  let v = 0n;
  for (const b of buf) v = (v << 8n) | BigInt(b);
  return v;
}

const pk = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined;
if (!pk) {
  console.error("DEPLOYER_PRIVATE_KEY is required");
  process.exit(1);
}
const account = privateKeyToAccount(pk);
log(`account = ${account.address}`);

const publicClient = createPublicClient({
  chain: { id: ARC_CHAIN_ID, name: "arc-testnet", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [ARC_RPC] } } } as const,
  transport: http(ARC_RPC),
});
const walletClient = createWalletClient({
  account,
  chain: publicClient.chain,
  transport: http(ARC_RPC),
});

// --- Generate fresh commitment ---
const nullifier = randomFieldElement() as Secret;
const secret    = randomFieldElement() as Secret;
// `label` is assigned by the pool when it stamps the deposit (poseidon
// over scope + index, post-deposit). We don't predict it — we read it
// from the Deposited event. We DO know value + precommitmentHash:
const fakeLabel = 1n; // placeholder for the commitment-hash computation below
const dummyCommitment = getCommitment(DEPOSIT_AMOUNT, fakeLabel, nullifier, secret);
const precommitmentHash = dummyCommitment.preimage.precommitment.hash;
log(`nullifier = ${nullifier}`);
log(`secret    = ${secret}`);
log(`precommitmentHash = ${precommitmentHash}`);

// --- ABIs (only what we need) ---
const ERC20_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address owner) view returns (uint256)",
]);
const ENTRYPOINT_ABI = parseAbi([
  "function deposit(address asset, uint256 value, uint256 precommitment) returns (uint256 commitment)",
]);
const POOL_ABI = parseAbi([
  "event Deposited(address indexed depositor, uint256 commitment, uint256 label, uint256 value, uint256 precommitmentHash)",
]);

// --- Approve USDC to entrypoint ---
log(`approving ${DEPOSIT_AMOUNT} USDC to entrypoint`);
const approveHash = await walletClient.writeContract({
  address: USDC as Address,
  abi: ERC20_ABI,
  functionName: "approve",
  args: [ENTRYPOINT, DEPOSIT_AMOUNT],
});
log(`approve tx ${approveHash} — waiting for receipt`);
await publicClient.waitForTransactionReceipt({ hash: approveHash });
log("approve confirmed");

// --- Deposit ---
log("calling entrypoint.deposit");
const depositHash = await walletClient.writeContract({
  address: ENTRYPOINT,
  abi: ENTRYPOINT_ABI,
  functionName: "deposit",
  args: [USDC as Address, DEPOSIT_AMOUNT, precommitmentHash as unknown as bigint],
});
log(`deposit tx ${depositHash} — waiting for receipt`);
const receipt = await publicClient.waitForTransactionReceipt({ hash: depositHash });
log(`deposit confirmed in block ${receipt.blockNumber}, status=${receipt.status}`);

// --- Parse Deposited event ---
const poolLogs = receipt.logs.filter(
  (l) => l.address.toLowerCase() === POOL_USDC.toLowerCase(),
);
if (poolLogs.length === 0) {
  console.error("No log emitted by the USDC pool — deposit may not have routed correctly");
  process.exit(1);
}
let depositedEvent: { label: bigint; value: bigint; commitment: bigint; precommitmentHash: bigint } | null = null;
for (const l of poolLogs) {
  try {
    const decoded = decodeEventLog({ abi: POOL_ABI, data: l.data, topics: l.topics });
    if (decoded.eventName === "Deposited") {
      depositedEvent = {
        label:             (decoded.args as { label: bigint }).label,
        value:             (decoded.args as { value: bigint }).value,
        commitment:        (decoded.args as { commitment: bigint }).commitment,
        precommitmentHash: (decoded.args as { precommitmentHash: bigint }).precommitmentHash,
      };
      break;
    }
  } catch { /* not a Deposited log */ }
}
if (!depositedEvent) {
  console.error("Failed to decode Deposited event from pool logs");
  process.exit(1);
}
log(`Deposited.label             = ${depositedEvent.label}`);
log(`Deposited.value             = ${depositedEvent.value}`);
log(`Deposited.commitment        = ${depositedEvent.commitment}`);
log(`Deposited.precommitmentHash = ${depositedEvent.precommitmentHash}`);

// Sanity check: the pool's commitment hash should equal what we'd
// compute locally given (value, label, nullifier, secret).
const localCommitment = getCommitment(
  depositedEvent.value,
  depositedEvent.label,
  nullifier,
  secret,
);
const localCommitmentHash = localCommitment.hash as unknown as bigint;
if (localCommitmentHash !== depositedEvent.commitment) {
  console.error(`commitment mismatch — chain: ${depositedEvent.commitment}, local: ${localCommitmentHash}`);
  process.exit(1);
}
log("commitment hash matches local computation ✓");

// --- Persist state for the withdraw step ---
const statePath = join(__dirname, ".b5-deposit-state.json");
writeFileSync(
  statePath,
  JSON.stringify(
    {
      account:           account.address,
      pool:              POOL_USDC,
      entrypoint:        ENTRYPOINT,
      asset:             USDC,
      value:             depositedEvent.value.toString(),
      nullifier:         nullifier.toString(),
      secret:            secret.toString(),
      label:             depositedEvent.label.toString(),
      precommitmentHash: depositedEvent.precommitmentHash.toString(),
      commitmentHash:    depositedEvent.commitment.toString(),
      depositTx:         depositHash,
      depositBlock:      receipt.blockNumber.toString(),
    },
    null,
    2,
  ),
);
log(`state persisted to ${statePath}`);

process.exit(0);
