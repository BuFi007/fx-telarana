// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Offline demo math for BUFX hedged LP vs unhedged v4 LP exposure.
/// @dev Values are quote-token/USD 1e18 fixed point. Run with:
///      forge script script/HedgedVsUnhedgedIlDemo.s.sol
contract HedgedVsUnhedgedIlDemo is Script {
    using SignedMathFormat for uint256;

    function run() external pure {
        console2.log("BUFX hedged vs unhedged LP IL demo");
        console2.log("All values are USD/USDC quote units scaled by 1e18.");

        _runCase({
            label: "cirBTC -10% move with 500 USDC fees",
            initialPriceE18: 100_000e18,
            finalPriceE18: 90_000e18,
            assetAmountE18: 1e18,
            feeIncomeE18: 500e18
        });

        _runCase({
            label: "JPYC +2% move with 20 USDC fees",
            initialPriceE18: 6666666666666666,
            finalPriceE18: 6800000000000000,
            assetAmountE18: 150_000e18,
            feeIncomeE18: 20e18
        });
    }

    function _runCase(
        string memory label,
        uint256 initialPriceE18,
        uint256 finalPriceE18,
        uint256 assetAmountE18,
        uint256 feeIncomeE18
    ) internal pure {
        uint256 initialQuoteE18 = Math.mulDiv(assetAmountE18, initialPriceE18, 1e18);
        uint256 initialValueE18 = initialQuoteE18 * 2;
        uint256 hodlFinalE18 = Math.mulDiv(assetAmountE18, finalPriceE18, 1e18) + initialQuoteE18;
        uint256 lpFinalNoFeesE18 = Math.mulDiv(assetAmountE18 * 2, Math.sqrt(initialPriceE18 * finalPriceE18), 1e18);
        int256 impermanentLossE18 = int256(lpFinalNoFeesE18) - int256(hodlFinalE18);
        int256 shortPnlE18 =
            Math.mulDiv(assetAmountE18, initialPriceE18 > finalPriceE18 ? initialPriceE18 - finalPriceE18 : finalPriceE18 - initialPriceE18, 1e18)
                .toInt(initialPriceE18 >= finalPriceE18);
        int256 unhedgedLpFinalE18 = int256(lpFinalNoFeesE18 + feeIncomeE18);
        int256 hedgedLpFinalE18 = unhedgedLpFinalE18 + shortPnlE18;

        console2.log("--------------------------------------------");
        console2.log(label);
        console2.log("initial value       ", initialValueE18);
        console2.log("hodl final          ", hodlFinalE18);
        console2.log("LP final no fees    ", lpFinalNoFeesE18);
        console2.log("IL vs HODL          ");
        console2.logInt(impermanentLossE18);
        console2.log("fee income          ", feeIncomeE18);
        console2.log("short hedge PnL     ");
        console2.logInt(shortPnlE18);
        console2.log("unhedged LP PnL     ");
        console2.logInt(unhedgedLpFinalE18 - int256(initialValueE18));
        console2.log("hedged LP PnL       ");
        console2.logInt(hedgedLpFinalE18 - int256(initialValueE18));
    }
}

library SignedMathFormat {
    function toInt(uint256 value, bool positive) internal pure returns (int256) {
        return positive ? int256(value) : -int256(value);
    }
}
