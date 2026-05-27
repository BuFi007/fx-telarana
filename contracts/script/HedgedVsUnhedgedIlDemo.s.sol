// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Offline hookathon demo math for BUFX hedged LP vs unhedged v4 LP exposure.
/// @dev Values are quote-token/USD 1e18 fixed point. Run with:
///      forge script script/HedgedVsUnhedgedIlDemo.s.sol -vvv
contract HedgedVsUnhedgedIlDemo is Script {
    using SignedMathFormat for uint256;

    address internal constant FX_HEDGE_HOOK = 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540;
    bytes32 internal constant CIRBTC_USDC_HEDGED_POOL_ID =
        0x33e42e1b20e3ea50b925963b583a033a8b959f53ffe76fb18cb97a6c6a171a8d;
    bytes32 internal constant CIRBTC_USDC_UNHEDGED_POOL_ID =
        keccak256("BUFX-DEMO:UNHEDGED-CIRBTC-USDC-POOL");

    function run() external pure {
        console2.log("BUFX hedged vs unhedged LP IL demo");
        console2.log("FxHedgeHook deployed at", FX_HEDGE_HOOK);
        console2.log("All value outputs are USD/USDC quote units scaled by 1e18.");

        _runCirBtcCase({
            initialPriceE18: 100_000e18,
            finalPriceE18: 90_000e18,
            assetAmountE18: 1e18,
            feeIncomeE18: 100e18
        });

        _runJpycReferenceCase({
            initialPriceE18: 6666666666666666,
            finalPriceE18: 6533333333333333,
            assetAmountE18: 150_000e18,
            feeIncomeE18: 20e18
        });
    }

    function _runCirBtcCase(
        uint256 initialPriceE18,
        uint256 finalPriceE18,
        uint256 assetAmountE18,
        uint256 feeIncomeE18
    ) internal pure {
        console2.log("--------------------------------------------");
        console2.log("1. LP deposits into cirBTC/USDC WITHOUT FxHedgeHook");
        console2.logBytes32(CIRBTC_USDC_UNHEDGED_POOL_ID);
        _runCase({
            label: "2-3. BTC drops 10%; unhedged LP earns fees but loses to IL",
            initialPriceE18: initialPriceE18,
            finalPriceE18: finalPriceE18,
            assetAmountE18: assetAmountE18,
            feeIncomeE18: feeIncomeE18
        });

        console2.log("--------------------------------------------");
        console2.log("4. LP deposits into cirBTC/USDC WITH FxHedgeHook");
        console2.log("hook", FX_HEDGE_HOOK);
        console2.logBytes32(CIRBTC_USDC_HEDGED_POOL_ID);
        console2.log("5-7. Same BTC drop; hook hedge offsets IL, LP keeps swap fees");
        _runCase({
            label: "hedged cirBTC/USDC",
            initialPriceE18: initialPriceE18,
            finalPriceE18: finalPriceE18,
            assetAmountE18: assetAmountE18,
            feeIncomeE18: feeIncomeE18
        });
    }

    function _runJpycReferenceCase(
        uint256 initialPriceE18,
        uint256 finalPriceE18,
        uint256 assetAmountE18,
        uint256 feeIncomeE18
    ) internal pure {
        console2.log("--------------------------------------------");
        console2.log("Reference: JPYC/USDC low-vol FX pool");
        _runCase({
            label: "JPYC -2% move with 20 USDC fees",
            initialPriceE18: initialPriceE18,
            finalPriceE18: finalPriceE18,
            assetAmountE18: assetAmountE18,
            feeIncomeE18: feeIncomeE18
        });
    }

    function _runCase(
        string memory label,
        uint256 initialPriceE18,
        uint256 finalPriceE18,
        uint256 assetAmountE18,
        uint256 feeIncomeE18
    ) internal pure {
        require(initialPriceE18 > 0 && finalPriceE18 > 0, "bad price");

        uint256 initialQuoteE18 = Math.mulDiv(assetAmountE18, initialPriceE18, 1e18);
        uint256 initialValueE18 = initialQuoteE18 * 2;
        uint256 hodlFinalE18 = Math.mulDiv(assetAmountE18, finalPriceE18, 1e18) + initialQuoteE18;
        uint256 lpFinalNoFeesE18 = Math.mulDiv(assetAmountE18 * 2, Math.sqrt(initialPriceE18 * finalPriceE18), 1e18);
        int256 impermanentLossE18 = int256(lpFinalNoFeesE18) - int256(hodlFinalE18);
        uint256 priceDeltaE18 = initialPriceE18 > finalPriceE18
            ? initialPriceE18 - finalPriceE18
            : finalPriceE18 - initialPriceE18;
        uint256 ilAbsE18 = impermanentLossE18 < 0 ? uint256(-impermanentLossE18) : uint256(impermanentLossE18);
        uint256 hedgeAssetAmountE18 = priceDeltaE18 == 0 ? 0 : Math.mulDiv(ilAbsE18, 1e18, priceDeltaE18);
        int256 shortPnlE18 = ilAbsE18.toInt(initialPriceE18 >= finalPriceE18);
        int256 unhedgedLpFinalE18 = int256(lpFinalNoFeesE18 + feeIncomeE18);
        int256 hedgedLpFinalE18 = unhedgedLpFinalE18 + shortPnlE18;

        console2.log(label);
        console2.log("initial value       ", initialValueE18);
        console2.log("hodl final          ", hodlFinalE18);
        console2.log("LP final no fees    ", lpFinalNoFeesE18);
        console2.log("IL vs HODL          ");
        console2.logInt(impermanentLossE18);
        console2.log("fee income          ", feeIncomeE18);
        console2.log("short hedge size    ", hedgeAssetAmountE18);
        console2.log("short hedge PnL     ");
        console2.logInt(shortPnlE18);
        console2.log("unhedged LP PnL     ");
        console2.logInt(unhedgedLpFinalE18 - int256(initialValueE18));
        console2.log("unhedged vs HODL    ");
        console2.logInt(unhedgedLpFinalE18 - int256(hodlFinalE18));
        console2.log("hedged LP PnL       ");
        console2.logInt(hedgedLpFinalE18 - int256(initialValueE18));
        console2.log("hedged vs HODL      ");
        console2.logInt(hedgedLpFinalE18 - int256(hodlFinalE18));
    }
}

library SignedMathFormat {
    function toInt(uint256 value, bool positive) internal pure returns (int256) {
        return positive ? int256(value) : -int256(value);
    }
}
