// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title IBufiKycPass
/// @notice Minimal verifier surface for Ghost Mode Bufi Wallet KYC/KYB passes.
///
/// Data flow:
///   Bufi Wallet
///       |
///       v
///   Ghost router / hook ---- hasValidPass(account) ----> Bufi pass verifier
///       |                                                   |
///       |<---------------- passLevel(account) --------------|
///       v
///   Fx hub action / Ghost pool
///
/// Implementations may use attestations, non-transferable tokens, or signed
/// credentials. Protocol contracts should depend only on this small interface.
interface IBufiKycPass {
    /// @notice Returns true only when `account` has a valid, unexpired, unrevoked
    ///         pass accepted for Ghost Mode.
    function hasValidPass(address account) external view returns (bool valid);

    /// @notice Pass level. Expected baseline: 0 = none, 1 = KYC, 2 = KYB.
    function passLevel(address account) external view returns (uint8 level);
}
