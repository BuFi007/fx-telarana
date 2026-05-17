// SPDX-License-Identifier: Apache-2.0
//
// Vendored from 0xbow-io/privacy-pools-core sdk exceptions (Apache-2.0).
// Trimmed to the surface we use; errors that depended on the upstream
// blockchain provider / data services are omitted (those services live
// in slice 4b).

export enum ErrorCode {
  INVALID_VALUE = "INVALID_VALUE",
  MERKLE_ERROR = "MERKLE_ERROR",
  PROOF_GENERATION_FAILED = "PROOF_GENERATION_FAILED",
  PROOF_VERIFICATION_FAILED = "PROOF_VERIFICATION_FAILED",
  CIRCUIT_NOT_INITIALIZED = "CIRCUIT_NOT_INITIALIZED",
}

export class PrivacyPoolError extends Error {
  constructor(public readonly code: ErrorCode, message: string) {
    super(message);
    this.name = "PrivacyPoolError";
  }
}

export class ProofError extends PrivacyPoolError {
  static generationFailed(ctx: Record<string, unknown>): ProofError {
    return new ProofError(
      ErrorCode.PROOF_GENERATION_FAILED,
      `Proof generation failed: ${JSON.stringify(ctx)}`,
    );
  }
  static verificationFailed(ctx: Record<string, unknown>): ProofError {
    return new ProofError(
      ErrorCode.PROOF_VERIFICATION_FAILED,
      `Proof verification failed: ${JSON.stringify(ctx)}`,
    );
  }
}
