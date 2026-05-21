// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxLiquidationEngine {
    function flagAccount(bytes32 marketId, address trader) external;

    /// @notice Anti-grief surface for the flag-bomb attack
    ///         (codex contract review P1 #5). Anyone can clear a flag
    ///         against `trader` once the position is no longer
    ///         liquidatable under the strict-oracle health check.
    ///         Caller MUST wrap the tx with the RedStone SDK so the
    ///         signed price payload lands in calldata tail.
    function rescindFlag(bytes32 marketId, address trader) external;

    function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        returns (uint256 liquidatorReward, int256 socializedLoss);
}
