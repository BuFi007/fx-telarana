// SPDX-License-Identifier: GPL-3.0
//
// Convert raw snarkjs Groth16 output into the on-chain calldata shape
// that `IEntrypoint.relay` / `relayCrossCurrency` expects.
//
// Why this lives in the GPL prover package: the input types are
// `snarkjs.Groth16Proof` and `snarkjs.PublicSignals`, which are GPL-3.0
// surfaces. The output is a plain string tuple that the Apache SDK
// consumes via `PrivacyContractsService.relay()` / `.relayCrossCurrency()`
// without re-importing snarkjs.
//
// Codex-r10 MED #2: prior to this helper, dApp consumers had to write
// the snarkjs→Solidity calldata reshaping themselves — easy to get
// wrong because Groth16's `pB` field uses the elliptic-curve point
// encoding `[[x1, x0], [y1, y0]]` (note the inner reversal) when the
// proof is consumed by Solidity precompiles. This helper bakes the
// correct ordering in once.

import type { Groth16Proof, PublicSignals } from "snarkjs";

import type { WithdrawProofTuple } from "@bu/fx-engine/privacy";

/**
 * Reshape `snarkjs.groth16.fullProve` output into the
 * `WithdrawProofTuple` the Solidity verifier consumes.
 *
 * snarkjs returns `pi_a` / `pi_b` / `pi_c` arrays where `pi_b` is
 * `[[b00, b01], [b10, b11], [1, 0]]` (the third pair is the infinity
 * marker we discard). The Solidity verifier expects the **inner pair
 * reversed** — `[[b01, b00], [b11, b10]]` — because EVM precompile
 * BN254 pairing inputs use the field-extension's `c0 + c1·X`
 * representation flipped from snarkjs's convention.
 *
 * The 8-element `publicSignals` order matches `ProofLib.WithdrawProof`:
 *   [0] newCommitmentHash
 *   [1] existingNullifierHash
 *   [2] withdrawnValue
 *   [3] stateRoot
 *   [4] stateTreeDepth
 *   [5] ASPRoot
 *   [6] ASPTreeDepth
 *   [7] context
 */
export function toWithdrawProofTuple(
  proof: Groth16Proof,
  publicSignals: PublicSignals,
): WithdrawProofTuple {
  if (publicSignals.length !== 8) {
    throw new Error(
      `expected 8 publicSignals (matches ProofLib.WithdrawProof), got ${publicSignals.length}`,
    );
  }
  if (proof.pi_a.length < 2 || proof.pi_b.length < 2 || proof.pi_c.length < 2) {
    throw new Error("malformed Groth16Proof: pi_a/pi_b/pi_c too short");
  }
  if (proof.pi_b[0].length !== 2 || proof.pi_b[1].length !== 2) {
    throw new Error("malformed Groth16Proof: pi_b inner pairs must be length 2");
  }

  // pi_b inner pairs are [c0, c1]; Solidity verifier wants [c1, c0].
  // pi_a / pi_c are simple [x, y] points (the 3rd element snarkjs adds
  // is the projective z=1 marker — discard).
  return {
    pA: [String(proof.pi_a[0]), String(proof.pi_a[1])],
    pB: [
      [String(proof.pi_b[0][1]), String(proof.pi_b[0][0])],
      [String(proof.pi_b[1][1]), String(proof.pi_b[1][0])],
    ],
    pC: [String(proof.pi_c[0]), String(proof.pi_c[1])],
    pubSignals: [
      String(publicSignals[0]), String(publicSignals[1]),
      String(publicSignals[2]), String(publicSignals[3]),
      String(publicSignals[4]), String(publicSignals[5]),
      String(publicSignals[6]), String(publicSignals[7]),
    ],
  };
}
