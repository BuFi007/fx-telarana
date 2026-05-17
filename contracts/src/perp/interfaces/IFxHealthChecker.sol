// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxHealthChecker {
    function healthFactor(bytes32 marketId, address trader) external view returns (uint256 ratioBps);
    function isLiquidatable(bytes32 marketId, address trader) external view returns (bool);
    function maintenanceMargin(bytes32 marketId, address trader) external view returns (uint256);
}
