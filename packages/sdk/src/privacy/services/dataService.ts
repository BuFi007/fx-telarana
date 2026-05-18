// SPDX-License-Identifier: Apache-2.0
//
// Lean DataService for the fx-Telarana Privacy Hook SDK.
//
// Adapted (heavily trimmed) from 0xbow's `data.service.ts` (Apache-2.0,
// commit a80836a4). 0xbow's version is 504 lines and handles multi-chain
// rate-limited paginated event scanning with multiple log-fetch
// strategies; this version is the LEAN surface a dApp needs to build
// withdrawal proofs:
//
//   1. Fetch IState.LeafInserted events for a pool (canonical order).
//      LeafInserted is emitted for BOTH deposits AND withdrawal change
//      notes — covering ALL leaves in the pool's state tree.
//   2. Reconstruct the LeanIMT and produce a Merkle inclusion proof for
//      a given commitment.
//   3. Optional getDepositsForPool() helper for dApp UIs that want to
//      surface specific Deposited events (e.g. user's deposit history).
//
// Codex-r10 HIGH: prior version sourced from Deposited only, missing
// the change-note commitments emitted by withdraw() — those users would
// have been unable to spend their change notes afterwards.
//
// No snarkjs dependency — this file stays clean Apache surface.

import { LeanIMT, type LeanIMTMerkleProof } from "@zk-kit/lean-imt";
import { poseidon } from "maci-crypto/build/ts/hashing.js";
import {
  type Address,
  type Hex,
  type PublicClient,
} from "viem";

import { PrivacyPoolError, ErrorCode } from "../exceptions.js";

/**
 * Output of {@link PrivacyDataService.getDepositsForPool} — one record
 * per `IPrivacyPool.Deposited` log, canonically ordered by
 * `(blockNumber, transactionIndex, logIndex)`.
 */
export interface DepositRecord {
  readonly blockNumber: bigint;
  readonly transactionIndex: number;
  readonly logIndex: number;
  readonly txHash: Hex;
  readonly depositor: Address;
  readonly commitment: bigint;
  readonly label: bigint;
  readonly value: bigint;
  readonly precommitmentHash: bigint;
}

/**
 * `IPrivacyPool.Deposited` ABI fragment — for dApp UI surfaces that
 * want to inspect deposit history specifically. NOT the source for
 * state-tree reconstruction (use `LeafInserted` for that — it covers
 * deposit + withdrawal change notes).
 *
 *   event Deposited(
 *     address indexed _depositor,
 *     uint256 _commitment,
 *     uint256 _label,
 *     uint256 _value,
 *     uint256 _precommitmentHash);
 */
const POOL_DEPOSITED_ABI = [{
  type: "event",
  name: "Deposited",
  inputs: [
    { name: "_depositor",         type: "address", indexed: true  },
    { name: "_commitment",        type: "uint256", indexed: false },
    { name: "_label",             type: "uint256", indexed: false },
    { name: "_value",             type: "uint256", indexed: false },
    { name: "_precommitmentHash", type: "uint256", indexed: false },
  ],
  anonymous: false,
}] as const;

/**
 * `IState.LeafInserted` ABI fragment — the authoritative source for
 * state-tree reconstruction. Emitted by `State._insert` on EVERY leaf
 * that lands in the LeanIMT: deposit commitments AND withdrawal change
 * notes (`_proof.newCommitmentHash()`).
 *
 *   event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root);
 */
const POOL_LEAF_INSERTED_ABI = [{
  type: "event",
  name: "LeafInserted",
  inputs: [
    { name: "_index", type: "uint256", indexed: false },
    { name: "_leaf",  type: "uint256", indexed: false },
    { name: "_root",  type: "uint256", indexed: false },
  ],
  anonymous: false,
}] as const;

export interface DataServiceConfig {
  /** Block to start scanning from. Default 0n (genesis). */
  fromBlock?: bigint;
  /** Block to stop scanning at. Default 'latest'. */
  toBlock?: bigint | "latest";
  /** Maximum block span per RPC call. Default 5000n. */
  maxRangePerCall?: bigint;
}

const DEFAULT_CFG: Required<DataServiceConfig> = {
  fromBlock: 0n,
  toBlock: "latest",
  maxRangePerCall: 5000n,
};

/**
 * Output of {@link PrivacyDataService.getLeavesForPool} — one record
 * per `IState.LeafInserted` log, canonically ordered. Covers BOTH
 * deposits AND withdrawal change notes.
 */
export interface LeafRecord {
  readonly blockNumber: bigint;
  readonly transactionIndex: number;
  readonly logIndex: number;
  /** Tree position assigned to this leaf at insertion time. */
  readonly index: bigint;
  readonly leaf: bigint;
  /** Root after insertion. */
  readonly root: bigint;
}

/**
 * Lean read-only privacy-pool indexer.
 */
export class PrivacyDataService {
  constructor(
    private readonly client: PublicClient,
    private readonly cfg: Required<DataServiceConfig> = DEFAULT_CFG,
  ) {}

  /**
   * Fetch every `LeafInserted` log emitted by `pool`, canonically
   * ordered. THIS is the source of truth for state-tree
   * reconstruction — covers deposit commitments + withdrawal change
   * notes (codex-r10 HIGH).
   */
  async getLeavesForPool(pool: Address): Promise<LeafRecord[]> {
    const endRequested = this.cfg.toBlock === "latest"
      ? await this.client.getBlockNumber()
      : this.cfg.toBlock;

    const out: LeafRecord[] = [];
    let cursor = this.cfg.fromBlock;
    while (cursor <= endRequested) {
      const windowEnd = cursor + this.cfg.maxRangePerCall - 1n > endRequested
        ? endRequested
        : cursor + this.cfg.maxRangePerCall - 1n;
      const logs = await this.client.getContractEvents({
        address:   pool,
        abi:       POOL_LEAF_INSERTED_ABI,
        eventName: "LeafInserted",
        fromBlock: cursor,
        toBlock:   windowEnd,
      });
      for (const ev of logs) {
        if (ev.blockNumber == null || ev.transactionIndex == null || ev.logIndex == null) continue;
        const a = ev.args as { _index?: bigint; _leaf?: bigint; _root?: bigint };
        if (typeof a._index !== "bigint" || typeof a._leaf !== "bigint" || typeof a._root !== "bigint") continue;
        out.push({
          blockNumber:      ev.blockNumber,
          transactionIndex: ev.transactionIndex,
          logIndex:         ev.logIndex,
          index:            a._index,
          leaf:             a._leaf,
          root:             a._root,
        });
      }
      cursor = windowEnd + 1n;
    }
    out.sort(compareCanonical);
    return out;
  }

  /**
   * Fetch every `Deposited` log emitted by `pool`. Useful for dApp UI
   * surfaces (e.g. "show me my deposit history") that need the value /
   * label / precommitment of each deposit specifically. NOT the source
   * for state-tree reconstruction — use {@link getLeavesForPool}.
   */
  async getDepositsForPool(pool: Address): Promise<DepositRecord[]> {
    const endRequested = this.cfg.toBlock === "latest"
      ? await this.client.getBlockNumber()
      : this.cfg.toBlock;

    const out: DepositRecord[] = [];
    let cursor = this.cfg.fromBlock;

    while (cursor <= endRequested) {
      const windowEnd = cursor + this.cfg.maxRangePerCall - 1n > endRequested
        ? endRequested
        : cursor + this.cfg.maxRangePerCall - 1n;

      const logs = await this.client.getContractEvents({
        address:   pool,
        abi:       POOL_DEPOSITED_ABI,
        eventName: "Deposited",
        fromBlock: cursor,
        toBlock:   windowEnd,
      });

      for (const ev of logs) {
        if (ev.blockNumber == null || ev.transactionIndex == null || ev.logIndex == null) {
          // Skip pending / malformed log; canonical ordering requires
          // these three fields. Real-world this would only happen on
          // pre-finality reads, which the caller controls via toBlock.
          continue;
        }
        const a = ev.args as {
          _depositor?: Address;
          _commitment?: bigint;
          _label?: bigint;
          _value?: bigint;
          _precommitmentHash?: bigint;
        };
        if (
          !a._depositor ||
          typeof a._commitment        !== "bigint" ||
          typeof a._label             !== "bigint" ||
          typeof a._value             !== "bigint" ||
          typeof a._precommitmentHash !== "bigint"
        ) continue;
        out.push({
          blockNumber:       ev.blockNumber,
          transactionIndex:  ev.transactionIndex,
          logIndex:          ev.logIndex,
          txHash:            ev.transactionHash as Hex,
          depositor:         a._depositor,
          commitment:        a._commitment,
          label:             a._label,
          value:             a._value,
          precommitmentHash: a._precommitmentHash,
        });
      }

      cursor = windowEnd + 1n;
    }

    out.sort(compareCanonical);
    return out;
  }

  /**
   * Reconstruct the pool's LeanIMT from ALL observed leaves (deposits
   * + withdrawal change notes) and return a Merkle inclusion proof for
   * `targetCommitment`. This is what the user's Groth16 withdrawal
   * proof binds against; the same algorithm runs on-chain in
   * `InternalLeanIMT`.
   *
   * Codex-r10 HIGH: prior version rebuilt from `Deposited` only,
   * missing the change notes that `withdraw()` inserts. After a
   * partial withdraw, a user holding the change note would have been
   * unable to spend it because their inclusion proof would target a
   * tree state that never existed on-chain.
   */
  async buildMerkleProof(
    pool: Address,
    targetCommitment: bigint,
  ): Promise<LeanIMTMerkleProof<bigint>> {
    const leaves = await this.getLeavesForPool(pool);
    const tree = new LeanIMT<bigint>((a, b) => poseidon([a, b]));
    for (const l of leaves) tree.insert(l.leaf);

    const idx = tree.indexOf(targetCommitment);
    if (idx === -1) {
      throw new PrivacyPoolError(
        ErrorCode.MERKLE_ERROR,
        `commitment 0x${targetCommitment.toString(16)} not found in pool ${pool} (size=${tree.size})`,
      );
    }
    const proof = tree.generateProof(idx);
    if (proof.siblings.length < 32) {
      proof.siblings = [
        ...proof.siblings,
        ...Array<bigint>(32 - proof.siblings.length).fill(0n),
      ];
    }
    return proof;
  }
}

/// Canonical-order comparator. Same shape as the ASP postman uses.
export function compareCanonical(
  a: { blockNumber: bigint; transactionIndex: number; logIndex: number },
  b: { blockNumber: bigint; transactionIndex: number; logIndex: number },
): number {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
  if (a.transactionIndex !== b.transactionIndex) return a.transactionIndex - b.transactionIndex;
  return a.logIndex - b.logIndex;
}
