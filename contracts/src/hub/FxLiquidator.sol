// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorpho, MarketParams as MorphoMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {IFxMarketRegistry} from "../interfaces/IFxMarketRegistry.sol";
import {IFxOracle} from "../interfaces/IFxOracle.sol";

/// @title FxLiquidator
/// @notice Thin keeper-callable wrapper around `IMorpho.liquidate` for fx-Telaraña markets.
///
/// Permissionless. Anyone can call. The keeper:
///   1. Bundles fresh Pyth (and Phase 0.5: RedStone) payloads via `IFxOracle.getMidWithUpdate`
///      so the oracle is fresh in the same tx as the liquidation.
///   2. Pays the debt asset via approval; receives seized collateral net of bonus.
///   3. Morpho enforces health-factor breach internally — this contract is just the conduit.
///
/// Bonus + LLTV semantics are inherited verbatim from Morpho Blue. No FX-bespoke logic.
contract FxLiquidator {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MorphoMarketParams;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IMorpho public immutable MORPHO;
    IFxMarketRegistry public immutable REGISTRY;
    IFxOracle public immutable ORACLE;

    error ZeroAddress();
    error InvalidLiquidation();

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address morpho_, address registry_, address oracle_) {
        if (morpho_ == address(0) || registry_ == address(0) || oracle_ == address(0)) revert ZeroAddress();
        MORPHO = IMorpho(morpho_);
        REGISTRY = IFxMarketRegistry(registry_);
        ORACLE = IFxOracle(oracle_);
    }

    /*//////////////////////////////////////////////////////////////
                                LIQUIDATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidate a position. Pass either `seizedAssets` or `repaidShares`; the other = 0.
    /// @dev    Caller must approve this contract for the debt asset (`loanToken`) up to the
    ///         repaid amount. Pyth + RedStone payloads keep the oracle fresh atomically.
    function liquidate(
        address loanToken,
        address collateralToken,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes[] calldata pythUpdate
    ) external payable returns (uint256 seized, uint256 repaid) {
        if ((seizedAssets == 0) == (repaidShares == 0)) revert InvalidLiquidation();

        // Freshen oracle in the same tx. RedStone signed payload is read from
        // msg.data tail — clients must wrap their tx with RedStone SDK.
        if (pythUpdate.length > 0) {
            ORACLE.getMidWithUpdate{value: msg.value}(loanToken, collateralToken, pythUpdate);
        }

        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);

        // The caller has approved THIS contract; we transfer in the repay funds and
        // approve Morpho. Morpho pulls the debt asset via transferFrom inside liquidate.
        // We compute an upper bound on debt repayment by previewing via Morpho if needed.
        // For simplicity we sweep caller's approved balance; any unused stays at caller.
        IERC20 debtToken = IERC20(loanToken);
        uint256 allowance = debtToken.allowance(msg.sender, address(this));
        if (allowance > 0) {
            debtToken.safeTransferFrom(msg.sender, address(this), allowance);
            if (debtToken.allowance(address(this), address(MORPHO)) < allowance) {
                debtToken.forceApprove(address(MORPHO), type(uint256).max);
            }
        }

        (seized, repaid) = MORPHO.liquidate(mp, borrower, seizedAssets, repaidShares, "");

        // Send seized collateral to the caller; refund any unused debt-side balance.
        IERC20 collat = IERC20(collateralToken);
        uint256 collatBal = collat.balanceOf(address(this));
        if (collatBal > 0) collat.safeTransfer(msg.sender, collatBal);

        uint256 debtRefund = debtToken.balanceOf(address(this));
        if (debtRefund > 0) debtToken.safeTransfer(msg.sender, debtRefund);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _morphoParams(address loanToken, address collateralToken)
        internal
        view
        returns (MorphoMarketParams memory)
    {
        IFxMarketRegistry.MarketParams memory p = REGISTRY.paramsOf(loanToken, collateralToken);
        return MorphoMarketParams({
            loanToken: p.loanToken,
            collateralToken: p.collateralToken,
            oracle: p.oracle,
            irm: p.irm,
            lltv: p.lltv
        });
    }
}
