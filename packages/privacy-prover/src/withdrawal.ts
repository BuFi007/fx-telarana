// SPDX-License-Identifier: GPL-3.0
//
// Vendored from 0xbow-io/privacy-pools-core
// sdk/src/core/withdrawal.service.ts (Apache-2.0 upstream).
// Re-licensed GPL-3.0 here because it directly depends on
// snarkjs (GPL-3.0). Codex-r8 HIGH: keeps the public Apache
// SDK clean of GPL dependencies.

import * as snarkjs from "snarkjs";

import {
  CircuitName,
  type CircuitsInterface,
  type Commitment,
  type WithdrawalProofInput,
} from "@bu/fx-engine/privacy";

import { ProofError, type WithdrawalProof } from "./types.js";

/** Lite shape mirroring 0xbow's `AccountCommitment` — kept private so
 *  consumers always pass a full {@link Commitment}. */
interface AccountCommitmentLite {
  readonly value: bigint;
  readonly label: bigint;
  readonly nullifier: bigint;
  readonly secret: bigint;
}

export class WithdrawalService {
  constructor(private readonly circuits: CircuitsInterface) {}

  async proveWithdrawal(
    commitment: Commitment | AccountCommitmentLite,
    input: WithdrawalProofInput,
  ): Promise<WithdrawalProof> {
    try {
      const inputSignals = this.prepareInputSignals(commitment, input);

      const wasm = await this.circuits.getWasm(CircuitName.Withdraw);
      const zkey = await this.circuits.getProvingKey(CircuitName.Withdraw);

      const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        inputSignals,
        wasm,
        zkey,
      );

      return { proof, publicSignals };
    } catch (error) {
      throw ProofError.generationFailed({
        error: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  async verifyWithdrawal(p: WithdrawalProof): Promise<boolean> {
    try {
      const vkeyBin = await this.circuits.getVerificationKey(
        CircuitName.Withdraw,
      );
      const vkey = JSON.parse(new TextDecoder("utf-8").decode(vkeyBin));
      return await snarkjs.groth16.verify(vkey, p.publicSignals, p.proof);
    } catch (error) {
      throw ProofError.verificationFailed({
        error: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  private prepareInputSignals(
    commitment: Commitment | AccountCommitmentLite,
    input: WithdrawalProofInput,
  ): Record<string, bigint | bigint[] | string> {
    let existingValue: bigint;
    let existingNullifier: bigint;
    let existingSecret: bigint;
    let label: bigint;
    if ("preimage" in commitment) {
      existingValue = commitment.preimage.value;
      existingNullifier = commitment.preimage.precommitment.nullifier;
      existingSecret = commitment.preimage.precommitment.secret;
      label = commitment.preimage.label;
    } else {
      existingValue = commitment.value;
      existingNullifier = commitment.nullifier;
      existingSecret = commitment.secret;
      label = commitment.label;
    }

    return {
      withdrawnValue: input.withdrawalAmount,
      stateRoot: input.stateRoot,
      stateTreeDepth: input.stateTreeDepth,
      ASPRoot: input.aspRoot,
      ASPTreeDepth: input.aspTreeDepth,
      context: input.context,

      label,
      existingValue,
      existingNullifier,
      existingSecret,
      newNullifier: input.newNullifier,
      newSecret: input.newSecret,

      stateSiblings: input.stateMerkleProof.siblings,
      stateIndex: BigInt(input.stateMerkleProof.index),
      ASPSiblings: input.aspMerkleProof.siblings,
      ASPIndex: BigInt(input.aspMerkleProof.index),
    };
  }
}
