// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxHedgeHook} from "../src/hub/FxHedgeHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary,
    toBalanceDelta
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract FxHedgeHookTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;
    bytes32 internal constant JPYC_MARKET_ID = keccak256("FX-PERP:JPYC/USDC");
    bytes32 internal constant PYTH_JPY_USD =
        0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;

    address internal poolManager = address(0xBEEF);
    address internal admin = address(0xA11CE);
    uint256 internal threshold = 100e18;

    FxHedgeHook internal hook;
    PoolKey internal key;
    bytes32 internal poolId;

    function setUp() public {
        hook = _deployHook();
        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(JPYC),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        poolId = PoolId.unwrap(key.toId());

        vm.prank(admin);
        hook.configurePool(key, JPYC_MARKET_ID, JPYC, 18, PYTH_JPY_USD, threshold, true);
    }

    function test_permissionsMatchMinedAddress() public view {
        uint160 flags = _hedgeHookFlags();
        assertEq(uint160(address(hook)) & uint160(Hooks.ALL_HOOK_MASK), flags);

        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertFalse(permissions.beforeAddLiquidity);
        assertTrue(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertTrue(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.afterSwapReturnDelta);
    }

    function test_configurePoolRejectsNonPoolToken() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(FxHedgeHook.HedgeTokenNotInPool.selector, poolId, address(0xBAD)));
        hook.configurePool(key, JPYC_MARKET_ID, address(0xBAD), 18, PYTH_JPY_USD, threshold, true);
    }

    function test_afterAddLiquidityTracksToken1ExposureAndRebalances() public {
        ModifyLiquidityParams memory params = _modifyParams(1);
        BalanceDelta delta = toBalanceDelta(-1_000e6, -2_000e18);

        vm.prank(poolManager);
        (bytes4 selector, BalanceDelta hookDelta) =
            hook.afterAddLiquidity(address(this), key, params, delta, BalanceDeltaLibrary.ZERO_DELTA, "");

        assertEq(selector, IHooks.afterAddLiquidity.selector);
        assertEq(hookDelta.amount0(), 0);
        assertEq(hookDelta.amount1(), 0);
        assertEq(hook.poolExposureE18(poolId), 2_000e18);
        assertEq(hook.poolHedgeSizeE18(poolId), -2_000e18);
        assertEq(hook.currentDelta(poolId), 0);
        assertTrue(hook.isDeltaNeutral(poolId));
    }

    function test_afterSwapRebalancesWhenPoolLosesHedgeToken() public {
        vm.prank(poolManager);
        hook.afterAddLiquidity(
            address(this),
            key,
            _modifyParams(1),
            toBalanceDelta(-1_000e6, -2_000e18),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100e6, sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        (bytes4 selector, int128 hookDelta) =
            hook.afterSwap(address(this), key, params, toBalanceDelta(-100e6, 100e18), "");

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        assertEq(hook.poolExposureE18(poolId), 1_900e18);
        assertEq(hook.poolHedgeSizeE18(poolId), -1_900e18);
        assertEq(hook.currentDelta(poolId), 0);
    }

    function test_afterRemoveLiquidityClosesHedgeWhenExposureGoesToZero() public {
        vm.prank(poolManager);
        hook.afterAddLiquidity(
            address(this),
            key,
            _modifyParams(1),
            toBalanceDelta(-1_000e6, -2_000e18),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        vm.prank(poolManager);
        hook.afterRemoveLiquidity(
            address(this),
            key,
            _modifyParams(-1),
            toBalanceDelta(1_000e6, 2_000e18),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        assertEq(hook.poolExposureE18(poolId), 0);
        assertEq(hook.poolHedgeSizeE18(poolId), 0);
        assertEq(hook.currentDelta(poolId), 0);
    }

    function test_afterSwapRevertsWhenNotPoolManager() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.expectRevert(abi.encodeWithSelector(FxHedgeHook.NotPoolManager.selector, address(this)));
        hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "");
    }

    function test_twapDeviationPausesHedgingAndAdminUnpauses() public {
        // Seed initial exposure + TWAP via a normal swap.
        // hedgeToken = JPYC (currency1). spotPrice = |d0| * 1e18 / |d1|.
        // For delta(-100e6, 100e18): spotPrice = 100e6 * 1e18 / 100e18 = 1e6.
        SwapParams memory normalSwap =
            SwapParams({zeroForOne: true, amountSpecified: -100e6, sqrtPriceLimitX96: 0});
        vm.prank(poolManager);
        hook.afterSwap(address(this), key, normalSwap, toBalanceDelta(-100e6, 100e18), "");

        // TWAP is seeded at 1e6. Verify hedge occurred.
        int256 hedgeAfterFirst = hook.poolHedgeSizeE18(poolId);
        assertEq(hedgeAfterFirst, 100e18, "first swap should have rebalanced");
        assertEq(hook.poolTwapPriceE18(poolId), 1e6, "TWAP should be seeded");

        // Second swap at a very different implied price (10x less JPYC per USDC)
        // AND large enough exposure change to exceed rebalance threshold (100e18).
        // delta(-1000e6, 100e18): spotPrice = 1000e6 * 1e18 / 100e18 = 10e6.
        // Deviation from TWAP(1e6): |10e6 - 1e6| / 1e6 = 900%, well above 2%.
        // Exposure delta = -rawToE18Signed(100e18, 18) = -100e18.
        // newExposure = -100e18 + (-100e18) = -200e18.
        // |newExposure + hedge| = |-200e18 + 100e18| = 100e18 >= threshold(100e18).
        SwapParams memory extremeSwap =
            SwapParams({zeroForOne: true, amountSpecified: -1000e6, sqrtPriceLimitX96: 0});
        vm.prank(poolManager);
        hook.afterSwap(address(this), key, extremeSwap, toBalanceDelta(-1000e6, 100e18), "");

        // Hedge should be paused.
        assertTrue(hook.hedgePaused(poolId), "hedge should be paused after TWAP deviation");
        // Hedge size should remain unchanged.
        assertEq(hook.poolHedgeSizeE18(poolId), hedgeAfterFirst, "hedge should not rebalance when paused");

        // While paused, another normal swap should NOT trigger rebalance either.
        vm.prank(poolManager);
        hook.afterSwap(address(this), key, normalSwap, toBalanceDelta(-100e6, 100e18), "");
        assertTrue(hook.hedgePaused(poolId), "hedge should stay paused");
        assertEq(hook.poolHedgeSizeE18(poolId), hedgeAfterFirst, "hedge still unchanged while paused");

        // Admin unpauses.
        vm.prank(admin);
        hook.unpauseHedge(poolId);
        assertFalse(hook.hedgePaused(poolId), "hedge should be unpaused by admin");

        // Feed enough normal-priced swaps to converge the TWAP EMA back close to
        // the normal spot price (1e6). Each step: twap = (twap*95 + 1e6*5)/100.
        // After enough iterations the deviation drops below 2% and rebalance fires.
        for (uint256 i; i < 80; ++i) {
            vm.prank(poolManager);
            hook.afterSwap(address(this), key, normalSwap, toBalanceDelta(-100e6, 100e18), "");
            if (!hook.hedgePaused(poolId) && hook.poolHedgeSizeE18(poolId) != hedgeAfterFirst) {
                break; // rebalance occurred
            }
            if (hook.hedgePaused(poolId)) {
                vm.prank(admin);
                hook.unpauseHedge(poolId);
            }
        }

        // After EMA convergence the hedge should have been updated.
        assertFalse(hook.hedgePaused(poolId), "hedge should be unpaused after convergence");
        assertTrue(hook.poolHedgeSizeE18(poolId) != hedgeAfterFirst, "hedge should have rebalanced after TWAP converged");
    }

    function _deployHook() internal returns (FxHedgeHook deployedHook) {
        bytes memory creationCode = abi.encodePacked(
            type(FxHedgeHook).creationCode,
            abi.encode(IPoolManager(poolManager), admin, threshold)
        );
        (address expected,) = HookMiner.find(address(this), _hedgeHookFlags(), creationCode, 500_000);
        deployCodeTo(_fxHedgeHookArtifact(), abi.encode(IPoolManager(poolManager), admin, threshold), expected);
        deployedHook = FxHedgeHook(expected);
    }

    function _modifyParams(int256 liquidityDelta)
        internal
        pure
        returns (ModifyLiquidityParams memory)
    {
        return ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });
    }

    function _hedgeHookFlags() internal pure returns (uint160) {
        return uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    }

    function _fxHedgeHookArtifact() internal view returns (string memory) {
        if (vm.isFile("out/FxHedgeHook.sol/FxHedgeHook.json")) return "out/FxHedgeHook.sol/FxHedgeHook.json";
        if (vm.isFile("out/FxHedgeHook.sol/FxHedgeHook.0.8.26.json")) {
            return "out/FxHedgeHook.sol/FxHedgeHook.0.8.26.json";
        }
        if (vm.isFile("out/FxHedgeHook.sol/FxHedgeHook.0.8.28.json")) {
            return "out/FxHedgeHook.sol/FxHedgeHook.0.8.28.json";
        }
        return "";
    }
}
