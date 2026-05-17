// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxPerpClearinghouse {
    struct MarketConfig {
        address baseToken;
        bool enabled;
        uint16 initialMarginBps;
        uint16 maintenanceMarginBps;
        uint16 tradingFeeBps;
        uint32 maxLeverageBps;
        uint256 maxOpenInterestUsd;
        uint256 maxSkewUsd;
    }

    struct Position {
        int256 sizeE18;
        uint256 entryPriceE18;
        uint256 marginReserved;
        uint64 lastFundingVersion;
    }

    function openOrIncrease(bytes32 marketId, address trader, int256 sizeDeltaE18, uint256 maxFee)
        external
        returns (bytes32 positionKey);
    function decreaseOrClose(bytes32 marketId, address trader, int256 sizeDeltaE18)
        external
        returns (uint256 marginReleased);
    function applyOrderFill(bytes32 marketId, address trader, int256 sizeDeltaE18, uint256 fillPriceE18, uint256 maxFee)
        external
        returns (bytes32 positionKey);
    function liquidatePosition(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        returns (uint256 marginReleased, int256 pnl, uint256 badDebt);
    function quoteFee(bytes32 marketId, address trader, int256 sizeDeltaE18)
        external
        view
        returns (uint256 fee, uint256 priceE18);
    function unrealizedPnl(bytes32 marketId, address trader) external view returns (int256 pnl);
    function position(bytes32 marketId, address trader) external view returns (Position memory);
    function marketConfig(bytes32 marketId) external view returns (MarketConfig memory);
    function openInterestLong(bytes32 marketId) external view returns (uint256);
    function openInterestShort(bytes32 marketId) external view returns (uint256);
    function maxOpenInterest(bytes32 marketId) external view returns (uint256);
    function marginAccount() external view returns (address);
    function fundingEngine() external view returns (address);
    function settleTraderFunding(address trader) external returns (int256 fundingPaid);
}
