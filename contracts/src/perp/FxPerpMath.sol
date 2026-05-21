// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title FxPerpMath
/// @notice Shared fixed-point helpers for the Phase B-E perp stack.
/// @dev Formula references:
///      - Required margin follows Synthetix v3 BFP `Position.getLiquidationMarginUsd`
///        / margin-ratio shape in `contracts/lib/synthetix-v3/markets/bfp-market`.
///      - PnL follows GMX Synthetics `PositionUtils.getPositionPnlUsd`.
///      - Average entry price follows the weighted notional pattern in GMX
///        `IncreasePositionUtils.increasePosition`.
///      Every multiply/divide uses OZ `Math.mulDiv`.
library FxPerpMath {
    using Math for uint256;
    using SafeCast for uint256;

    error Int256Overflow();

    uint256 internal constant BPS = 10_000;
    uint8 internal constant E18_DECIMALS = 18;

    function abs(int256 value) internal pure returns (uint256) {
        if (value == type(int256).min) revert Int256Overflow();
        return uint256(value < 0 ? -value : value);
    }

    function sameSign(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount.mulDiv(10 ** uint256(toDecimals - fromDecimals), 1);
        return amount.mulDiv(1, 10 ** uint256(fromDecimals - toDecimals));
    }

    function notionalFromSize(uint256 sizeAbsE18, uint256 priceE18, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 notionalE18 = sizeAbsE18.mulDiv(priceE18, 1e18);
        return scaleDecimals(notionalE18, E18_DECIMALS, quoteDecimals);
    }

    function requiredMargin(uint256 notional, uint16 initialMarginBps) internal pure returns (uint256) {
        return notional.mulDiv(initialMarginBps, BPS);
    }

    function fee(uint256 notional, uint16 feeBps) internal pure returns (uint256) {
        return notional.mulDiv(feeBps, BPS);
    }

    function pnl(int256 sizeE18, uint256 entryPriceE18, uint256 currentPriceE18, uint8 quoteDecimals)
        internal
        pure
        returns (int256)
    {
        if (sizeE18 == 0 || entryPriceE18 == currentPriceE18) return 0;
        int256 priceDelta = currentPriceE18.toInt256() - entryPriceE18.toInt256();
        uint256 pnlE18 = abs(sizeE18).mulDiv(abs(priceDelta), 1e18);
        uint256 pnlAtomic = scaleDecimals(pnlE18, E18_DECIMALS, quoteDecimals);
        if (pnlAtomic > uint256(type(int256).max)) revert Int256Overflow();
        bool negative = (sizeE18 < 0) != (priceDelta < 0);
        int256 signedPnl = pnlAtomic.toInt256();
        return negative ? -signedPnl : signedPnl;
    }

    function weightedEntryPrice(
        int256 currentSizeE18,
        uint256 currentEntryPriceE18,
        int256 deltaE18,
        uint256 fillPriceE18
    ) internal pure returns (uint256) {
        if (currentSizeE18 == 0) return fillPriceE18;
        uint256 currentAbs = abs(currentSizeE18);
        uint256 deltaAbs = abs(deltaE18);
        uint256 nextAbs = currentAbs + deltaAbs;
        uint256 weightedCurrent = currentAbs.mulDiv(currentEntryPriceE18, 1);
        uint256 weightedDelta = deltaAbs.mulDiv(fillPriceE18, 1);
        return (weightedCurrent + weightedDelta).mulDiv(1, nextAbs);
    }
}
