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
//   1. Fetch IPrivacyPool.Deposited events for a pool (canonical order).
//   2. Reconstruct the LeanIMT and produce a Merkle inclusion proof for
//      a given commitment.
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
 * Minimal `IPrivacyPool.Deposited` ABI fragment. Matches the on-chain
 * emission verified in the postman tests (codex-r3 HIGH #1):
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
 * Lean read-only privacy-pool indexer.
 */
export class PrivacyDataService {
  constructor(
    private readonly client: PublicClient,
    private readonly cfg: Required<DataServiceConfig> = DEFAULT_CFG,
  ) {}

  /**
   * Fetch every `Deposited` log emitted by `pool` in [fromBlock, toBlock],
   * canonically ordered. Pages through the range respecting
   * `cfg.maxRangePerCall` so this works on RPC providers with strict
   * pagination ceilings.
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
   * Reconstruct the pool's LeanIMT from all observed deposits and
   * return a Merkle inclusion proof for `targetCommitment`.
   *
   * This proof is what the user's Groth16 withdrawal proof binds
   * against. The same algorithm runs on-chain in `InternalLeanIMT`.
   */
  async buildMerkleProof(
    pool: Address,
    targetCommitment: bigint,
  ): Promise<LeanIMTMerkleProof<bigint>> {
    const deposits = await this.getDepositsForPool(pool);
    const tree = new LeanIMT<bigint>((a, b) => poseidon([a, b]));
    for (const d of deposits) tree.insert(d.commitment);

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
