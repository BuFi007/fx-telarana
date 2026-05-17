// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxLiquidationEngine {
    function flagAccount(bytes32 marketId, address trader) external;
    function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        returns (uint256 liquidatorReward, int256 socializedLoss);
}
