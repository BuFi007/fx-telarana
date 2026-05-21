// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxHealthChecker {
    function healthFactor(bytes32 marketId, address trader) external view returns (uint256 ratioBps);
    function isLiquidatable(bytes32 marketId, address trader) external view returns (bool);
    function maintenanceMargin(bytes32 marketId, address trader) external view returns (uint256);

    /// @notice Same as {healthFactor}, but uses the strict deviation-gated
    ///         oracle path. Caller MUST wrap the tx with the RedStone SDK
    ///         so the signed payload is in calldata tail. Reverts if Pyth
    ///         and RedStone disagree beyond the configured gate.
    function healthFactorVerified(bytes32 marketId, address trader) external view returns (uint256 ratioBps);

    /// @notice Same as {isLiquidatable}, but uses the strict deviation-gated
    ///         oracle path. Used by `FxLiquidationEngine` to ensure a Pyth
    ///         flicker can't trigger a wrongful flag or liquidation.
    ///         Codex contract review P1 #1.
    function isLiquidatableVerified(bytes32 marketId, address trader) external view returns (bool);
}
