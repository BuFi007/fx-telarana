// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title IFxGhostWithdrawalVerifier
/// @notice Minimal verifier interface for Ghost Mode withdrawal proofs.
///
/// Data flow:
///   offchain prover
///       |
///       v
///   FxGhostWithdrawalRouter ---- verifyGhostWithdrawal(...) ----> verifier
///       |
///       v
///   FxGhostCommitmentRegistry consumes nullifier, then router pays recipient
///
/// V1 keeps the verifier mockable. Production deployments should replace this
/// with audited verifier logic and verifier-key governance.
interface IFxGhostWithdrawalVerifier {
    function verifyGhostWithdrawal(
        bytes32 root,
        bytes32 nullifierHash,
        bytes32 routeId,
        address passAccount,
        address token,
        uint256 amount,
        address recipient,
        bytes32 metadataRef,
        bytes calldata proof
    ) external view returns (bool valid);
}
