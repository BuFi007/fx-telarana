// SPDX-License-Identifier: Apache-2.0
/// Machine-readable reasons for Ghost Mode eligibility. Pasillo's
/// /fx/eligibility endpoint returns one of these per wallet. Backend gates,
/// frontend renders. Adding cases is backwards-compatible.
export enum EligibilityReason {
  OK = "OK",
  NO_BUFI_WORKSPACE = "NO_BUFI_WORKSPACE",
  NO_SUBSCRIPTION = "NO_SUBSCRIPTION",
  NO_BUFI_WALLET = "NO_BUFI_WALLET",
  NO_BUFI_KYC_PASS = "NO_BUFI_KYC_PASS",
  NO_BUFI_KYB_PASS = "NO_BUFI_KYB_PASS",
  KYC_PENDING = "KYC_PENDING",
  KYB_PENDING = "KYB_PENDING",
  PASS_EXPIRED = "PASS_EXPIRED",
  PASS_REVOKED = "PASS_REVOKED",
  COMPLIANCE_BLOCK = "COMPLIANCE_BLOCK",
  GHOST_ROUTE_UNAVAILABLE = "GHOST_ROUTE_UNAVAILABLE",
}

export enum BufiPassLevel {
  None = "NONE",
  Kyc = "KYC",
  Kyb = "KYB",
}

export interface EligibilityResult {
  public: true;
  ghost: boolean;
  reason: EligibilityReason;
  passLevel?: BufiPassLevel;
}
