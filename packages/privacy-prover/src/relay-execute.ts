// SPDX-License-Identifier: GPL-3.0
//
// proveAndBuildRelayExecute — the shared engine for the own-stack private
// execution router (FxPrivacyEntrypoint.relayExecute). PURE proof construction:
// no private keys, no on-chain writes. Reconstructs the pool's real merkle tree
// from chain, tuple-encodes the ExecutionRelayData, computes the context, and
// produces the Groth16 withdraw proof. The caller (relayer / provider / MCP)
// ensures the ASP root is published and submits the result.
//
// Extracted from the proven b5-execute round-trip (live-green on Arc). Same
// withdraw circuit + deployed verifier — no new ceremony.

import { encodeAbiParameters, parseAbi, type Address, type PublicClient } from "viem";
import * as snarkjs from "snarkjs";
import {
  bigintToHash,
  calculateContext,
  generateMerkleProof,
  type Withdrawal,
} from "@bu/fx-engine/privacy";

/** A spendable shielded note (the user's deposit secrets + on-chain leaf). */
export interface ShieldedNote {
  nullifier: bigint;
  secret: bigint;
  value: bigint;
  label: bigint;
  commitmentHash: bigint;
}

export interface RelayExecuteParams {
  /** Read-only client for the chain the pool lives on. */
  publicClient: PublicClient;
  pool: Address;
  entrypoint: Address;
  note: ShieldedNote;
  /** Registered execution adapter id + its calldata (e.g. abi-encoded MarketParams). */
  adapterId: bigint;
  adapterData: `0x${string}`;
  /** onBehalf / output recipient (a stealth address in production — Phase 3). */
  recipient: Address;
  feeRecipient: Address;
  relayFeeBPS: bigint;
  /** ASP-tree root to prove against. Single-leaf model = note.label. */
  aspRoot: bigint;
  /** Groth16 withdraw circuit artifacts. */
  wasmBytes: Uint8Array;
  zkeyBytes: Uint8Array;
  /** Lower bound for the leaf binary-search (default 0n; set near pool deploy to speed up). */
  searchLoBlock?: bigint;
}

export interface WithdrawProofTuple {
  pA: [bigint, bigint];
  pB: [[bigint, bigint], [bigint, bigint]];
  pC: [bigint, bigint];
  pubSignals: [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
}

export interface RelayExecuteResult {
  /** The Withdrawal to pass to relayExecute (processooor = entrypoint, data = ExecutionRelayData). */
  withdrawal: Withdrawal;
  proof: WithdrawProofTuple;
  scope: bigint;
  context: bigint;
  stateRoot: bigint;
  leafCount: number;
}

const LEAF_INSERTED = parseAbi(["event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root)"]);
const SIZE_ABI = parseAbi(["function currentTreeSize() view returns (uint256)"]);
const SCOPE_ABI = parseAbi(["function SCOPE() view returns (uint256)"]);
const ROOT_ABI = parseAbi(["function currentRoot() view returns (uint256)"]);

/**
 * Reconstruct the pool's real LeanIMT from chain — binary-search currentTreeSize()
 * by block (historical eth_call, range-limit-free) to find each leaf's insertion
 * block, then a small getLogs window of LeafInserted per block (deposits AND
 * withdrawal change-notes). Needs NO indexer. Returns the merkle proof for `leaf`.
 */
export async function reconstructStateTree(
  client: PublicClient,
  pool: Address,
  leaf: bigint,
  loBlock = 0n,
): Promise<{ root: bigint; siblings: bigint[]; index: number; leaves: bigint[]; treeSize: number }> {
  const treeSize = Number(
    (await client.readContract({ address: pool, abi: SIZE_ABI, functionName: "currentTreeSize" })) as bigint,
  );
  const latest = await client.getBlockNumber();
  const sizeAt = async (b: bigint): Promise<number> => {
    try {
      return Number(
        (await client.readContract({ address: pool, abi: SIZE_ABI, functionName: "currentTreeSize", blockNumber: b })) as bigint,
      );
    } catch {
      return 0; // pre-deploy / no code → 0 leaves
    }
  };
  const blockForSize = async (s: number): Promise<bigint> => {
    let lo = loBlock, hi = latest, ans = hi;
    while (lo <= hi) {
      const mid = (lo + hi) / 2n;
      if ((await sizeAt(mid)) >= s) { ans = mid; hi = mid - 1n; } else { lo = mid + 1n; }
    }
    return ans;
  };
  const blocks = new Set<bigint>();
  for (let s = 1; s <= treeSize; s++) blocks.add(await blockForSize(s));
  const seen = new Set<string>();
  const collected: Array<{ args: { _index: bigint; _leaf: bigint }; transactionHash: string | null; logIndex: number | null }> = [];
  for (const b of blocks) {
    const lo = b > 8n ? b - 8n : 0n;
    const chunk = (await client.getLogs({ address: pool, event: LEAF_INSERTED[0], fromBlock: lo, toBlock: b + 8n })) as typeof collected;
    for (const l of chunk) {
      const k = `${l.transactionHash}:${l.logIndex}`;
      if (!seen.has(k)) { seen.add(k); collected.push(l); }
    }
  }
  const leaves = collected
    .sort((a, b) => Number(a.args._index - b.args._index))
    .map((l) => l.args._leaf);
  const mp = generateMerkleProof(leaves, leaf);
  return { root: mp.root, siblings: mp.siblings, index: mp.index, leaves, treeSize };
}

/** ABI-encode ExecutionRelayData. It has a dynamic `bytes` field → it's a dynamic
 *  tuple, so the on-chain abi.decode(data,(ExecutionRelayData)) expects a SINGLE
 *  tuple (leading offset). Encoding 5 separate params would decode adapterId as
 *  the offset → empty revert. (Live-green fix.) */
export function encodeExecutionRelayData(args: {
  adapterId: bigint; recipient: Address; feeRecipient: Address; relayFeeBPS: bigint; data: `0x${string}`;
}): `0x${string}` {
  return encodeAbiParameters(
    [{
      type: "tuple", name: "d", components: [
        { type: "uint256", name: "adapterId" },
        { type: "address", name: "recipient" },
        { type: "address", name: "feeRecipient" },
        { type: "uint256", name: "relayFeeBPS" },
        { type: "bytes", name: "data" },
      ],
    }],
    [args],
  );
}

function randomFieldElement(): bigint {
  const b = new Uint8Array(31);
  crypto.getRandomValues(b);
  let v = 0n;
  for (const x of b) v = (v << 8n) | BigInt(x);
  return v;
}

/**
 * Build the withdrawal + Groth16 proof for a relayExecute. Pure: no signer, no
 * writes. Caller publishes the ASP root (== aspRoot) and submits
 * relayExecute(withdrawal, proof, scope).
 */
export async function proveAndBuildRelayExecute(p: RelayExecuteParams): Promise<RelayExecuteResult> {
  const scope = (await p.publicClient.readContract({ address: p.pool, abi: SCOPE_ABI, functionName: "SCOPE" })) as bigint;

  const state = await reconstructStateTree(p.publicClient, p.pool, p.note.commitmentHash, p.searchLoBlock);
  const onchainRoot = (await p.publicClient.readContract({ address: p.pool, abi: ROOT_ABI, functionName: "currentRoot" })) as bigint;
  if (state.root !== onchainRoot) {
    throw new Error(`reconstructed state root ${state.root} != pool.currentRoot() ${onchainRoot}`);
  }
  const asp = generateMerkleProof([p.aspRoot], p.aspRoot);

  const data = encodeExecutionRelayData({
    adapterId: p.adapterId, recipient: p.recipient, feeRecipient: p.feeRecipient,
    relayFeeBPS: p.relayFeeBPS, data: p.adapterData,
  });
  const withdrawal: Withdrawal = { processooor: p.entrypoint, data };
  const context = BigInt(calculateContext(withdrawal, bigintToHash(scope)));

  const input = {
    withdrawnValue: p.note.value,
    stateRoot: state.root, stateTreeDepth: BigInt(state.siblings.length),
    ASPRoot: asp.root, ASPTreeDepth: BigInt(asp.siblings.length),
    context, label: p.note.label,
    existingValue: p.note.value, existingNullifier: p.note.nullifier, existingSecret: p.note.secret,
    newNullifier: randomFieldElement(), newSecret: randomFieldElement(),
    stateSiblings: state.siblings, stateIndex: BigInt(state.index),
    ASPSiblings: asp.siblings, ASPIndex: BigInt(asp.index),
  };

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, p.wasmBytes, p.zkeyBytes);
  const sig = publicSignals as string[];
  if (sig.length !== 8) throw new Error(`publicSignals length ${sig.length} != 8`);

  const pA: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
  const pB: [[bigint, bigint], [bigint, bigint]] = [
    [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
    [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
  ];
  const pC: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];
  const pubSignals = sig.map((s) => BigInt(s)) as unknown as WithdrawProofTuple["pubSignals"];

  return { withdrawal, proof: { pA, pB, pC, pubSignals }, scope, context, stateRoot: state.root, leafCount: state.leaves.length };
}
