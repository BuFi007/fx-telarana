// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title HedgedVsUnhedgedIlDemo
/// @notice Full on-chain demo: reads deployed FxHedgeHook, PoolManager and
///         TurboFeeVault state on Arc Testnet, then projects hedged vs
///         unhedged IL outcomes.
/// @dev Run against the live testnet (read-only, no broadcast needed):
///      forge script script/HedgedVsUnhedgedIlDemo.s.sol -vvv \
///        --rpc-url https://rpc.drpc.testnet.arc.network
contract HedgedVsUnhedgedIlDemo is Script {
    using SignedMathFormat for uint256;
    using StateLibrary for IPoolManager;

    // ── Deployed addresses (Arc Testnet 5042002) ──────────────────────
    IPoolManager internal constant POOL_MANAGER =
        IPoolManager(0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E);
    address internal constant FX_HEDGE_HOOK =
        0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540;
    address internal constant TURBO_FEE_VAULT =
        0x929e222CBbC154f8e75a8DEF951288886Df70531;

    // ── Pool IDs from deployment JSON ─────────────────────────────────
    bytes32 internal constant CIRBTC_USDC_POOL_ID =
        0x33e42e1b20e3ea50b925963b583a033a8b959f53ffe76fb18cb97a6c6a171a8d;
    bytes32 internal constant JPYC_USDC_POOL_ID =
        0xd19440c05e5c0d9549187e01162e8aeab29c196c3177cde6360db740b8aa3504;

    // ── Market IDs ────────────────────────────────────────────────────
    bytes32 internal constant CIRBTC_MARKET_ID =
        0x238aacf17c8d170ad55905cd1c217ae2db8338354b1235059fb0f096e20b777a;
    bytes32 internal constant JPYC_MARKET_ID =
        0x848d2b05de70986fa3661af2a50953b537f05066eedc33c18cde1bd12cdd0a2d;

    // ── Pyth feed IDs ─────────────────────────────────────────────────
    bytes32 internal constant BTC_USD_PYTH =
        0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant JPY_USD_PYTH =
        0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;

    // ── Synthetic pool ID for the unhedged comparison ─────────────────
    bytes32 internal constant CIRBTC_USDC_UNHEDGED_POOL_ID =
        keccak256("BUFX-DEMO:UNHEDGED-CIRBTC-USDC-POOL");

    // ── Minimal interfaces for external calls ─────────────────────────
    // (avoids importing full source from src/ which another agent owns)

    function run() external view {
        console2.log("============================================");
        console2.log("  BUFX Hedged vs Unhedged IL Demo (on-chain)");
        console2.log("============================================");
        console2.log("");

        // ── Step 1: Pool state from PoolManager ──────────────────────
        _logStep1_PoolState();

        // ── Step 2: Hedge hook exposure + delta neutrality ───────────
        _logStep2_HedgeState();

        // ── Step 3: TurboFeeVault stats ──────────────────────────────
        _logStep3_VaultStats();

        // ── Step 4: Per-pool hedge configuration ─────────────────────
        _logStep4_HedgeConfig();

        // ── Step 5: Offline IL math projection ───────────────────────
        _logStep5_IlProjection();
    }

    // ═════════════════════════════════════════════════════════════════
    //  STEP 1 — Current pool state from PoolManager
    // ═════════════════════════════════════════════════════════════════
    function _logStep1_PoolState() internal view {
        console2.log("--------------------------------------------");
        console2.log("STEP 1: Pool state (PoolManager @ ", address(POOL_MANAGER), ")");
        console2.log("");

        // ── cirBTC / USDC pool ──
        _logPoolSlot0("cirBTC/USDC", CIRBTC_USDC_POOL_ID);

        // ── JPYC / USDC pool ──
        _logPoolSlot0("JPYC/USDC", JPYC_USDC_POOL_ID);
    }

    function _logPoolSlot0(string memory label, bytes32 rawPoolId) internal view {
        PoolId pid = PoolId.wrap(rawPoolId);
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            POOL_MANAGER.getSlot0(pid);
        uint128 liquidity = POOL_MANAGER.getLiquidity(pid);

        console2.log("  Pool:", label);
        console2.log("    sqrtPriceX96  :", sqrtPriceX96);
        console2.log("    tick          :");
        console2.logInt(int256(tick));
        console2.log("    protocolFee   :", protocolFee);
        console2.log("    lpFee (bps)   :", lpFee);
        console2.log("    liquidity     :", liquidity);
        console2.log("");
    }

    // ═════════════════════════════════════════════════════════════════
    //  STEP 2 — Hedge hook exposure & delta neutrality
    // ═════════════════════════════════════════════════════════════════
    function _logStep2_HedgeState() internal view {
        console2.log("--------------------------------------------");
        console2.log("STEP 2: FxHedgeHook state (@ ", FX_HEDGE_HOOK, ")");
        console2.log("");

        _logHedgeExposure("cirBTC/USDC", CIRBTC_USDC_POOL_ID);
        _logHedgeExposure("JPYC/USDC", JPYC_USDC_POOL_ID);
    }

    function _logHedgeExposure(string memory label, bytes32 poolId) internal view {
        // Read exposure, hedge size, currentDelta, isDeltaNeutral
        (bool ok1, bytes memory data1) = FX_HEDGE_HOOK.staticcall(
            abi.encodeWithSignature("poolExposureE18(bytes32)", poolId)
        );
        (bool ok2, bytes memory data2) = FX_HEDGE_HOOK.staticcall(
            abi.encodeWithSignature("poolHedgeSizeE18(bytes32)", poolId)
        );
        (bool ok3, bytes memory data3) = FX_HEDGE_HOOK.staticcall(
            abi.encodeWithSignature("currentDelta(bytes32)", poolId)
        );
        (bool ok4, bytes memory data4) = FX_HEDGE_HOOK.staticcall(
            abi.encodeWithSignature("isDeltaNeutral(bytes32)", poolId)
        );

        console2.log("  Pool:", label);

        if (ok1) {
            int256 exposure = abi.decode(data1, (int256));
            console2.log("    exposureE18    :");
            console2.logInt(exposure);
        } else {
            console2.log("    exposureE18    : (call failed)");
        }

        if (ok2) {
            int256 hedgeSize = abi.decode(data2, (int256));
            console2.log("    hedgeSizeE18   :");
            console2.logInt(hedgeSize);
        } else {
            console2.log("    hedgeSizeE18   : (call failed)");
        }

        if (ok3) {
            int256 delta = abi.decode(data3, (int256));
            console2.log("    currentDelta   :");
            console2.logInt(delta);
        } else {
            console2.log("    currentDelta   : (call failed)");
        }

        if (ok4) {
            bool neutral = abi.decode(data4, (bool));
            console2.log("    isDeltaNeutral :", neutral);
        } else {
            console2.log("    isDeltaNeutral : (call reverted -- pool may not be configured)");
        }
        console2.log("");
    }

    // ═════════════════════════════════════════════════════════════════
    //  STEP 3 — TurboFeeVault stats
    // ═════════════════════════════════════════════════════════════════
    function _logStep3_VaultStats() internal view {
        console2.log("--------------------------------------------");
        console2.log("STEP 3: TurboFeeVault state (@ ", TURBO_FEE_VAULT, ")");
        console2.log("");

        _logVaultUint("totalFeesCollected", "totalFeesCollected()");
        _logVaultUint("totalStaked       ", "totalStaked()");
        _logVaultUint("totalShares       ", "totalShares()");
        _logVaultUint("insuranceBalance  ", "insuranceBalance()");
        _logVaultUint("compositeApy (e18)", "compositeApy()");
        _logVaultUint("totalDeposits     ", "totalDeposits()");
        _logVaultUint("totalYieldDistrib.", "totalYieldDistributed()");

        // protocolTreasury address
        (bool ok, bytes memory data) = TURBO_FEE_VAULT.staticcall(
            abi.encodeWithSignature("protocolTreasury()")
        );
        if (ok) {
            address treasury = abi.decode(data, (address));
            console2.log("    protocolTreasury:", treasury);
        }
        console2.log("");
    }

    function _logVaultUint(string memory label, string memory sig) internal view {
        (bool ok, bytes memory data) = TURBO_FEE_VAULT.staticcall(
            abi.encodeWithSignature(sig)
        );
        if (ok) {
            uint256 val = abi.decode(data, (uint256));
            console2.log("   ", label, val);
        } else {
            console2.log("   ", label, "(call failed)");
        }
    }

    // ═════════════════════════════════════════════════════════════════
    //  STEP 4 — Per-pool hedge configuration
    // ═════════════════════════════════════════════════════════════════
    function _logStep4_HedgeConfig() internal view {
        console2.log("--------------------------------------------");
        console2.log("STEP 4: Pool hedge configurations");
        console2.log("");

        _logPoolConfig("cirBTC/USDC", CIRBTC_USDC_POOL_ID, BTC_USD_PYTH);
        _logPoolConfig("JPYC/USDC", JPYC_USDC_POOL_ID, JPY_USD_PYTH);
    }

    function _logPoolConfig(
        string memory label,
        bytes32 poolId,
        bytes32 expectedPythFeed
    ) internal view {
        // poolConfigs returns the struct fields individually via the auto-getter
        (bool ok, bytes memory data) = FX_HEDGE_HOOK.staticcall(
            abi.encodeWithSignature("poolConfigs(bytes32)", poolId)
        );

        console2.log("  Pool:", label);
        console2.log("    poolId          :");
        console2.logBytes32(poolId);

        if (ok && data.length >= 192) {
            (
                bytes32 marketId,
                address hedgeToken,
                uint8 hedgeTokenDecimals,
                bytes32 pythFeedId,
                uint256 rebalanceThresholdE18,
                bool enabled
            ) = abi.decode(data, (bytes32, address, uint8, bytes32, uint256, bool));

            console2.log("    marketId        :");
            console2.logBytes32(marketId);
            console2.log("    hedgeToken      :", hedgeToken);
            console2.log("    hedgeTokenDec   :", hedgeTokenDecimals);
            console2.log("    pythFeedId      :");
            console2.logBytes32(pythFeedId);
            console2.log("    rebalThreshold  :", rebalanceThresholdE18);
            console2.log("    enabled         :", enabled);

            if (pythFeedId != expectedPythFeed) {
                console2.log("    WARNING: pythFeedId does not match expected feed!");
                console2.log("    expected        :");
                console2.logBytes32(expectedPythFeed);
            }
        } else {
            console2.log("    (pool not configured or call failed)");
        }
        console2.log("");
    }

    // ═════════════════════════════════════════════════════════════════
    //  STEP 5 — Offline IL math projection (original hookathon math)
    // ═════════════════════════════════════════════════════════════════
    function _logStep5_IlProjection() internal pure {
        console2.log("--------------------------------------------");
        console2.log("STEP 5: What-if IL projection (offline math)");
        console2.log("All value outputs are USD/USDC quote units scaled by 1e18.");
        console2.log("");

        // ── cirBTC/USDC: BTC drops 10% ──
        console2.log("--- Scenario A: cirBTC/USDC, BTC drops 10% ---");
        console2.log("");
        console2.log("  Unhedged LP (no FxHedgeHook):");
        console2.logBytes32(CIRBTC_USDC_UNHEDGED_POOL_ID);
        _runCase({
            label: "    BTC 100k -> 90k, 1 BTC position, 100 USDC fees",
            initialPriceE18: 100_000e18,
            finalPriceE18: 90_000e18,
            assetAmountE18: 1e18,
            feeIncomeE18: 100e18
        });

        console2.log("");
        console2.log("  Hedged LP (WITH FxHedgeHook):");
        console2.log("    hook:", FX_HEDGE_HOOK);
        console2.logBytes32(CIRBTC_USDC_POOL_ID);
        console2.log("    Same BTC drop; hook hedge offsets IL, LP keeps fees");
        _runCase({
            label: "    hedged cirBTC/USDC",
            initialPriceE18: 100_000e18,
            finalPriceE18: 90_000e18,
            assetAmountE18: 1e18,
            feeIncomeE18: 100e18
        });

        // ── JPYC/USDC: JPY drops 2% ──
        console2.log("");
        console2.log("--- Scenario B: JPYC/USDC, JPY drops 2% ---");
        _runCase({
            label: "    JPYC -2% with 20 USDC fees",
            initialPriceE18: 6666666666666666,
            finalPriceE18: 6533333333333333,
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
        require(initialPriceE18 > 0 && finalPriceE18 > 0, "bad price");

        uint256 initialQuoteE18 = Math.mulDiv(assetAmountE18, initialPriceE18, 1e18);
        uint256 initialValueE18 = initialQuoteE18 * 2;
        uint256 hodlFinalE18 = Math.mulDiv(assetAmountE18, finalPriceE18, 1e18) + initialQuoteE18;
        uint256 lpFinalNoFeesE18 = Math.mulDiv(
            assetAmountE18 * 2,
            Math.sqrt(initialPriceE18 * finalPriceE18),
            1e18
        );
        int256 impermanentLossE18 = int256(lpFinalNoFeesE18) - int256(hodlFinalE18);
        uint256 priceDeltaE18 = initialPriceE18 > finalPriceE18
            ? initialPriceE18 - finalPriceE18
            : finalPriceE18 - initialPriceE18;
        uint256 ilAbsE18 = impermanentLossE18 < 0
            ? uint256(-impermanentLossE18)
            : uint256(impermanentLossE18);
        uint256 hedgeAssetAmountE18 = priceDeltaE18 == 0
            ? 0
            : Math.mulDiv(ilAbsE18, 1e18, priceDeltaE18);
        int256 shortPnlE18 = ilAbsE18.toInt(initialPriceE18 >= finalPriceE18);
        int256 unhedgedLpFinalE18 = int256(lpFinalNoFeesE18 + feeIncomeE18);
        int256 hedgedLpFinalE18 = unhedgedLpFinalE18 + shortPnlE18;

        console2.log(label);
        console2.log("      initial value     ", initialValueE18);
        console2.log("      hodl final        ", hodlFinalE18);
        console2.log("      LP final no fees  ", lpFinalNoFeesE18);
        console2.log("      IL vs HODL        ");
        console2.logInt(impermanentLossE18);
        console2.log("      fee income        ", feeIncomeE18);
        console2.log("      short hedge size  ", hedgeAssetAmountE18);
        console2.log("      short hedge PnL   ");
        console2.logInt(shortPnlE18);
        console2.log("      unhedged LP PnL   ");
        console2.logInt(unhedgedLpFinalE18 - int256(initialValueE18));
        console2.log("      unhedged vs HODL  ");
        console2.logInt(unhedgedLpFinalE18 - int256(hodlFinalE18));
        console2.log("      hedged LP PnL     ");
        console2.logInt(hedgedLpFinalE18 - int256(initialValueE18));
        console2.log("      hedged vs HODL    ");
        console2.logInt(hedgedLpFinalE18 - int256(hodlFinalE18));
    }
}

library SignedMathFormat {
    function toInt(uint256 value, bool positive) internal pure returns (int256) {
        return positive ? int256(value) : -int256(value);
    }
}
