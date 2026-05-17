// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxMarginAccount {
    function depositMargin(address trader, uint256 amount) external;
    function withdrawMargin(address trader, uint256 amount) external;
    function marginOf(address trader) external view returns (uint256);
    function reservedMarginOf(address trader) external view returns (uint256);
    function freeMarginOf(address trader) external view returns (uint256);
    function reserveMargin(address trader, uint256 amount) external;
    function releaseMargin(address trader, uint256 amount) external;
    function realizePnl(address trader, int256 pnl) external returns (uint256 badDebt);
    function payLiquidatorReward(address trader, address liquidator, uint256 amount) external;
    function marginDecimals() external view returns (uint8);
}
