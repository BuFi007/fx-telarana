// SPDX-License-Identifier: Apache-2.0
//
// Vendored from 0xbow-io/privacy-pools-core sdk constants.ts (Apache-2.0).
// SNARK_SCALAR_FIELD is the BN254 prime; identical to the Solidity-side
// constant in contracts/lib/privacy-pools/contracts/lib/Constants.sol.

export const SNARK_SCALAR_FIELD_STRING =
  "21888242871839275222246405745257275088548364400416034343698204186575808495617";

export const SNARK_SCALAR_FIELD = BigInt(SNARK_SCALAR_FIELD_STRING);

/// @notice Max state tree depth enforced by `PrivacyPool.validWithdrawal`.
export const MAX_TREE_DEPTH = 32;
