// SPDX-License-Identifier: GPL-3.0
//
// Type imports from snarkjs live in this package (NOT in @bu/fx-engine)
// to keep the public Apache SDK free of GPL-typed surfaces.

import type { Groth16Proof, PublicSignals } from "snarkjs";

/**
 * Groth16 withdrawal proof returned by {@link WithdrawalService.proveWithdrawal}.
 */
export interface WithdrawalProof {
  readonly proof: Groth16Proof;
  readonly publicSignals: PublicSignals;
}

export { ProofError } from "@bu/fx-engine/privacy";
