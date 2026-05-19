// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFxHealthChecker} from "./interfaces/IFxHealthChecker.sol";
import {IFxMarginAccount} from "./interfaces/IFxMarginAccount.sol";
import {IFxPerpClearinghouse} from "./interfaces/IFxPerpClearinghouse.sol";
import {FxPerpMath} from "./FxPerpMath.sol";

/// @title FxHealthChecker
/// @notice Read-only risk surface for per-market maintenance and liquidation.
/// @dev Mirrors the Synthetix v3 BFP `LiquidationModule.isMarginLiquidatable`
///      shape: compare account equity against maintenance margin, where
///      maintenance margin is notional times the market risk ratio.
contract FxHealthChecker is IFxHealthChecker, AccessControl {
    using Math for uint256;

    IFxPerpClearinghouse public immutable CLEARINGHOUSE;
    IFxMarginAccount public immutable MARGIN;
    uint8 public immutable MARGIN_DECIMALS;

    error ZeroAddress();

    constructor(address clearinghouse_, address marginAccount_, address initialAdmin) {
        if (clearinghouse_ == address(0) || marginAccount_ == address(0) || initialAdmin == address(0)) {
            revert ZeroAddress();
        }
        CLEARINGHOUSE = IFxPerpClearinghouse(clearinghouse_);
        MARGIN = IFxMarginAccount(marginAccount_);
        MARGIN_DECIMALS = IFxMarginAccount(marginAccount_).marginDecimals();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    function healthFactor(bytes32 marketId, address trader) external view returns (uint256 ratioBps) {
        uint256 maint = maintenanceMargin(marketId, trader);
        if (maint == 0) return type(uint256).max;
        uint256 equity = _equity(marketId, trader);
        return equity.mulDiv(10_000, maint);
    }

    function isLiquidatable(bytes32 marketId, address trader) external view returns (bool) {
        uint256 maint = maintenanceMargin(marketId, trader);
        if (maint == 0) return false;
        return _equity(marketId, trader) < maint;
    }

    /// @inheritdoc IFxHealthChecker
    function healthFactorVerified(bytes32 marketId, address trader) external view returns (uint256 ratioBps) {
        uint256 maint = maintenanceMargin(marketId, trader);
        if (maint == 0) return type(uint256).max;
        uint256 equity = _equityVerified(marketId, trader);
        return equity.mulDiv(10_000, maint);
    }

    /// @inheritdoc IFxHealthChecker
    function isLiquidatableVerified(bytes32 marketId, address trader) external view returns (bool) {
        uint256 maint = maintenanceMargin(marketId, trader);
        if (maint == 0) return false;
        return _equityVerified(marketId, trader) < maint;
    }

    function maintenanceMargin(bytes32 marketId, address trader) public view returns (uint256) {
        IFxPerpClearinghouse.Position memory p = CLEARINGHOUSE.position(marketId, trader);
        if (p.sizeE18 == 0) return 0;
        IFxPerpClearinghouse.MarketConfig memory config = CLEARINGHOUSE.marketConfig(marketId);
        uint256 notional = FxPerpMath.notionalFromSize(FxPerpMath.abs(p.sizeE18), p.entryPriceE18, MARGIN_DECIMALS);
        return notional.mulDiv(config.maintenanceMarginBps, 10_000);
    }

    function _equity(bytes32 marketId, address trader) internal view returns (uint256) {
        uint256 margin = MARGIN.marginOf(trader);
        int256 pnl = CLEARINGHOUSE.unrealizedPnl(marketId, trader);
        if (pnl >= 0) return margin + FxPerpMath.abs(pnl);
        uint256 loss = FxPerpMath.abs(pnl);
        return loss >= margin ? 0 : margin - loss;
    }

    /// Strict-oracle counterpart of {_equity}. Codex contract review
    /// P1 #1: any health gate that controls liquidation must read the
    /// verified oracle path so a Pyth flicker can't flip the gate.
    function _equityVerified(bytes32 marketId, address trader) internal view returns (uint256) {
        uint256 margin = MARGIN.marginOf(trader);
        int256 pnl = CLEARINGHOUSE.unrealizedPnlVerified(marketId, trader);
        if (pnl >= 0) return margin + FxPerpMath.abs(pnl);
        uint256 loss = FxPerpMath.abs(pnl);
        return loss >= margin ? 0 : margin - loss;
    }
}
