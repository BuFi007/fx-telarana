// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IMorpho, MarketParams as MorphoMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";

/// @title FxReceipt
/// @notice ERC-4626 wrapper around a single Morpho Blue supply position.
///
/// One FxReceipt per loan asset (`fxUSDC` wraps the USDC supply position in market
/// M2; `fxEURC` wraps the EURC supply position in market M1). Lenders get a single
/// receipt token they can transfer, list on DEXes, or route through a Ghost
/// privacy wrapper.
///
/// Conversion math defers to Morpho Blue's `SharesMathLib` so receipt redemption
/// always matches what `IMorpho.withdraw` would return.
contract FxReceipt is ERC4626 {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MorphoMarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IMorpho public immutable MORPHO;
    Id      public immutable MARKET_ID;

    // Cache market params for repeated calls (Morpho's API takes the full struct).
    MorphoMarketParams private _marketParams;

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address morpho_,
        MorphoMarketParams memory marketParams_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        require(morpho_ != address(0), "FxReceipt: morpho 0");
        require(marketParams_.loanToken == address(asset_), "FxReceipt: asset mismatch");

        MORPHO = IMorpho(morpho_);
        MARKET_ID = marketParams_.id();
        _marketParams = marketParams_;
    }

    /*//////////////////////////////////////////////////////////////
                                ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Total assets owned by this contract as a Morpho supplier.
    /// @dev Reads Morpho's view of the wrapper's supply position (NOT
    /// `asset.balanceOf(this)`). Raw USDC transferred directly to this contract
    /// therefore does not affect share pricing — defeating the classical
    /// ERC-4626 direct-donation inflation attack. The wrapper can still be
    /// attacked via a Morpho-side donation (`MORPHO.supply(params, x, 0,
    /// wrapper, "")` mints shares to this contract's Morpho position); the
    /// `_decimalsOffset()` override below is the defense against that variant.
    /// Audit reference: `reports/AUDIT_REPORT.md` v1.2.2 R1.
    function totalAssets() public view override returns (uint256) {
        return MORPHO.expectedSupplyAssets(_marketParams, address(this));
    }

    /// @dev Virtual-shares boost against ERC-4626 first-depositor inflation.
    /// OZ default is 0, which leaves the share-rounding window open until the
    /// pool has scale. Returning 6 forces `_convertToShares` to scale by 1e6,
    /// raising the attacker's required donation by the same factor and making
    /// the steal economically negative-EV at any realistic victim deposit.
    /// Audit reference: `reports/AUDIT_REPORT.md` v1.2.2 R1 — operative attack
    /// is Morpho-side donation via `MORPHO.supply(params, x, 0, wrapper, "")`.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /*//////////////////////////////////////////////////////////////
                                HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev On deposit: pull assets in (ERC4626 default), then push into Morpho.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        IERC20 a = IERC20(asset());
        if (a.allowance(address(this), address(MORPHO)) < assets) {
            a.forceApprove(address(MORPHO), type(uint256).max);
        }
        MORPHO.supply(_marketParams, assets, 0, address(this), "");
    }

    /// @dev On withdraw: pull assets out of Morpho first, then standard ERC4626 outflow.
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        MORPHO.withdraw(_marketParams, assets, 0, address(this), address(this));
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function marketParams() external view returns (MorphoMarketParams memory) {
        return _marketParams;
    }
}
