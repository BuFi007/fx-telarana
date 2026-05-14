/// Machine-readable reasons for confidential-mode eligibility. Pasillo's
/// /fx/eligibility endpoint returns one of these per wallet. Backend gates,
/// frontend renders. Adding cases is backwards-compatible.
export enum EligibilityReason {
  OK = "OK",
  NO_BUFI_WORKSPACE = "NO_BUFI_WORKSPACE",
  NO_SUBSCRIPTION = "NO_SUBSCRIPTION",
  NO_HINKAL_ACCESS_TOKEN = "NO_HINKAL_ACCESS_TOKEN",
  KYC_PENDING = "KYC_PENDING",
  COMPLIANCE_BLOCK = "COMPLIANCE_BLOCK",
}

export interface EligibilityResult {
  public: true;
  confidential: boolean;
  reason: EligibilityReason;
}
