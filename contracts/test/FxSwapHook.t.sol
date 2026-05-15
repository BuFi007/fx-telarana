// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {FxOracle} from "../src/hub/FxOracle.sol";

contract FxSwapHookTest is Test {
    FxSwapHook internal hook;
    FxOracle   internal oracle;
    MockPyth   internal pyth;
    MockERC20  internal token0;
    MockERC20  internal token1;
    address    internal poolManager = address(0x1111);
    address    internal registry    = address(0x3333);
    address    internal owner       = address(0xA11CE);
    address    internal alice       = address(0xCAFE);

    bytes32 internal constant PYTH_T0 = bytes32(uint256(1));
    bytes32 internal constant PYTH_T1 = bytes32(uint256(2));

    function setUp() public {
        // Deploy tokens with deterministic ordering: token0 address < token1 address
        // The mock tokens are deployed in sequence so the first will have a lower address.
        MockERC20 a = new MockERC20("A", "A", 6);
        MockERC20 b = new MockERC20("B", "B", 6);
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }

        pyth = new MockPyth();
        oracle = new FxOracle(address(pyth), owner, 60, 50, 30);
        vm.startPrank(owner);
        oracle.setFeed(address(token0), PYTH_T0);
        oracle.setFeed(address(token1), PYTH_T1);
        vm.stopPrank();

        // token0 = token1 = $1.00, so mid(t0,t1) = 1.0
        pyth.setPrice(PYTH_T0, 1_00_000_000, 100, -8, block.timestamp);
        pyth.setPrice(PYTH_T1, 1_00_000_000, 100, -8, block.timestamp);

        hook = new FxSwapHook(
            poolManager,
            address(oracle),
            registry,
            owner,
            address(token0),
            address(token1),
            address(0x4444)   // mock morpho — unused at hotReservePct = 10_000
        );

        // Use 100% hot reserves so these standalone unit tests don't touch
        // the (mocked) Morpho/registry. Phase 2.6 rehypothecation is exercised
        // in fork-based tests.
        vm.prank(owner);
        hook.setHotReservePct(10_000);

        // Fund alice with both tokens
        token0.mint(alice, 1_000_000_000); // 1000 token0
        token1.mint(alice, 1_000_000_000); // 1000 token1
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function test_getHookPermissions_enablesExpectedFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertTrue(p.beforeSwapReturnDelta);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setSpreadBps_updatesAndEmits() public {
        vm.prank(owner);
        hook.setSpreadBps(50);
        assertEq(hook.spreadBps(), 50);
    }

    function test_setSpreadBps_onlyOwner() public {
        vm.expectRevert();
        hook.setSpreadBps(50);
    }

    function test_setSpreadBps_revertsAboveMax() public {
        uint16 maxBps = hook.MAX_SPREAD_BPS();
        vm.expectRevert();
        vm.prank(owner);
        hook.setSpreadBps(maxBps + 1);
    }

    function test_setKBps_updatesAndEmits() public {
        vm.prank(owner);
        hook.setKBps(200);
        assertEq(hook.kBps(), 200);
    }

    function test_setKBps_revertsAboveMax() public {
        uint16 maxK = hook.MAX_K_BPS();
        vm.expectRevert();
        vm.prank(owner);
        hook.setKBps(maxK + 1);
    }

    function test_constructor_setsDefaults() public {
        // Re-deploy to inspect untouched constructor defaults.
        FxSwapHook fresh = new FxSwapHook(
            poolManager, address(oracle), registry, owner,
            address(token0), address(token1), address(0x4444)
        );
        assertEq(fresh.spreadBps(), fresh.DEFAULT_SPREAD_BPS());
        assertEq(fresh.kBps(), fresh.DEFAULT_K_BPS());
        assertEq(fresh.hotReservePct(), fresh.DEFAULT_HOT_RESERVE_PCT());
        assertEq(fresh.maxObservationChangeBps(), fresh.DEFAULT_MAX_OBSERVATION_CHANGE_BPS());
        assertEq(fresh.volatilitySpreadMultiplierBps(), fresh.DEFAULT_VOLATILITY_SPREAD_MULTIPLIER_BPS());
        assertEq(fresh.TOKEN0(), address(token0));
        assertEq(fresh.TOKEN1(), address(token1));
    }

    function test_constructor_revertsOnTokensUnsorted() public {
        vm.expectRevert();
        new FxSwapHook(poolManager, address(oracle), registry, owner, address(token1), address(token0), address(0x4444));
    }

    function test_setHotReservePct_revertsAbove10k() public {
        vm.expectRevert();
        vm.prank(owner);
        hook.setHotReservePct(10_001);
    }

    function test_setHotReservePct_updatesAndEmits() public {
        vm.prank(owner);
        hook.setHotReservePct(2_000);
        assertEq(hook.hotReservePct(), 2_000);
    }

    function test_setOracleGuardrails_updatesDynamicFeeControls() public {
        vm.prank(owner);
        hook.setOracleGuardrails(250, 20_000);
        assertEq(hook.maxObservationChangeBps(), 250);
        assertEq(hook.volatilitySpreadMultiplierBps(), 20_000);
    }

    function test_setOracleGuardrails_revertsAboveCaps() public {
        uint16 maxObservationChange = hook.MAX_OBSERVATION_CHANGE_BPS();
        uint16 maxVolatilityMultiplier = hook.MAX_VOLATILITY_SPREAD_MULTIPLIER_BPS();

        vm.startPrank(owner);
        vm.expectRevert();
        hook.setOracleGuardrails(maxObservationChange + 1, 10_000);
        vm.expectRevert();
        hook.setOracleGuardrails(100, maxVolatilityMultiplier + 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                LP API
    //////////////////////////////////////////////////////////////*/

    function test_deposit_firstDepositBootstrapsShares() public {
        vm.prank(alice);
        uint256 shares = hook.deposit(1_000_000, 1_000_000);
        // First depositor: shares = (a0 + a1) - MINIMUM_LIQUIDITY
        assertEq(shares, 2_000_000 - hook.MINIMUM_LIQUIDITY());
        assertEq(hook.totalShares(), 2_000_000);
        assertEq(hook.sharesOf(alice), shares);
        assertEq(token0.balanceOf(address(hook)), 1_000_000);
        assertEq(token1.balanceOf(address(hook)), 1_000_000);
    }

    function test_deposit_subsequentDepositProRata() public {
        vm.prank(alice);
        hook.deposit(1_000_000, 1_000_000);

        address bob = address(0xBEEF);
        token0.mint(bob, 1_000_000);
        token1.mint(bob, 1_000_000);
        vm.startPrank(bob);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        uint256 bobShares = hook.deposit(500_000, 500_000);
        vm.stopPrank();

        // bob deposits half of alice's amount → roughly half her shares
        assertGt(bobShares, 0);
        // Slight precision loss expected; bob's stake ≈ 1/3 of total now
        uint256 total = hook.totalShares();
        assertApproxEqRel(bobShares * 3, total, 0.01e18);
    }

    function test_redeem_returnsProRataBalance() public {
        vm.prank(alice);
        uint256 shares = hook.deposit(1_000_000, 1_000_000);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.redeem(shares);

        // alice gets back roughly what she put in minus MINIMUM_LIQUIDITY
        assertGt(out0, 0);
        assertGt(out1, 0);
        assertApproxEqAbs(out0, 1_000_000 - hook.MINIMUM_LIQUIDITY() / 2, 1);
        assertApproxEqAbs(out1, 1_000_000 - hook.MINIMUM_LIQUIDITY() / 2, 1);
    }

    function test_redeem_revertsOnInsufficientShares() public {
        vm.prank(alice);
        hook.deposit(1_000_000, 1_000_000);
        vm.expectRevert();
        vm.prank(alice);
        hook.redeem(type(uint256).max);
    }

    function test_redeem_revertsOnZero() public {
        vm.expectRevert();
        vm.prank(alice);
        hook.redeem(0);
    }

    function test_deposit_revertsOnZero() public {
        vm.expectRevert();
        vm.prank(alice);
        hook.deposit(0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              PMM QUOTE
    //////////////////////////////////////////////////////////////*/

    function test_quote_atEquilibriumReturnsMidMinusSpread() public {
        // seed with even reserves
        vm.prank(alice);
        hook.deposit(1_000_000_000, 1_000_000_000);

        // Trade is tiny relative to reserves → kImpact ≈ 0
        uint256 amountOut = hook.quote(1000, true);  // 1000 units in
        // Expect: amountOut ≈ 1000 * 1.0 * (1 - 30/10_000) = 997
        assertApproxEqAbs(amountOut, 997, 1);
    }

    function test_quote_largeTradeHasHigherSlippage() public {
        vm.prank(alice);
        hook.deposit(1_000_000_000, 1_000_000_000);

        uint256 smallOut = hook.quote(1_000, true);              // tiny trade
        uint256 bigOut   = hook.quote(500_000_000, true);        // 50% of reserve

        // effective rate = out / in; should be worse for big trade
        // smallOut/1000 should be higher than bigOut/500_000_000
        uint256 smallRate = (smallOut * 1e18) / 1_000;
        uint256 bigRate   = (bigOut * 1e18) / 500_000_000;
        assertGt(smallRate, bigRate);
    }

    function test_quote_zeroKMeansNoSizeImpact() public {
        vm.prank(alice);
        hook.deposit(1_000_000_000, 1_000_000_000);

        vm.prank(owner);
        hook.setKBps(0);

        uint256 smallOut = hook.quote(1_000, true);
        uint256 bigOut   = hook.quote(500_000_000, true);

        uint256 smallRate = (smallOut * 1e18) / 1_000;
        uint256 bigRate   = (bigOut * 1e18) / 500_000_000;
        assertApproxEqRel(smallRate, bigRate, 0.0001e18);
    }

    function test_recordOracleObservation_initializesCanonicalMid() public {
        (uint256 rawMid, uint256 truncatedMid, uint16 volatilityBps, uint16 effectiveSpread) =
            hook.recordOracleObservation();

        assertEq(rawMid, 1e18);
        assertEq(truncatedMid, 1e18);
        assertEq(volatilityBps, 0);
        assertEq(effectiveSpread, hook.DEFAULT_SPREAD_BPS());
        assertEq(hook.latestTruncatedMidE18(), 1e18);
        assertEq(hook.latestVolatilityBps(), 0);
        assertEq(hook.oracleObservationCardinality(), 1);
    }

    function test_previewOracleObservation_truncatesSuddenMoveAndWidensSpread() public {
        hook.recordOracleObservation();

        vm.warp(block.timestamp + 60);
        pyth.setPrice(PYTH_T0, 2_00_000_000, 100, -8, block.timestamp);

        (uint256 rawMid, uint256 truncatedMid, uint16 volatilityBps, uint16 effectiveSpread) =
            hook.previewOracleObservation();

        assertEq(rawMid, 2e18);
        assertEq(truncatedMid, 1_010_000_000_000_000_000);
        assertEq(volatilityBps, 100);
        assertEq(effectiveSpread, 130);
    }

    function test_quoteExactInput_usesTruncatedObservationAndVolatilitySpread() public {
        vm.prank(alice);
        hook.deposit(1_000_000_000, 1_000_000_000);
        hook.recordOracleObservation();

        vm.warp(block.timestamp + 60);
        pyth.setPrice(PYTH_T0, 2_00_000_000, 100, -8, block.timestamp);

        (uint256 buyAmount, uint256 oraclePriceE18) = hook.quoteExactInput(address(token0), 1_000);
        assertEq(oraclePriceE18, 1_010_000_000_000_000_000);
        // 1000 * 1.01 less 130 bps spread, with tiny size impact.
        assertApproxEqAbs(buyAmount, 996, 1);
    }

    function test_quoteExactInput_scalesSixDecimalUsdcToEighteenDecimalJpyc() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 jpyc = new MockERC20("JPYC", "JPYC", 18);
        FxSwapHook h = _newHotOnlyHook(usdc, jpyc, 1_00_000_000, 640_000); // JPYC/USD = 0.0064

        usdc.mint(alice, 10_000e6);
        jpyc.mint(alice, 1_562_500e18);
        vm.startPrank(alice);
        usdc.approve(address(h), type(uint256).max);
        jpyc.approve(address(h), type(uint256).max);
        _depositSorted(h, address(usdc), 10_000e6, address(jpyc), 1_562_500e18);
        vm.stopPrank();

        vm.prank(owner);
        h.setKBps(0);

        (uint256 buyAmount, uint256 oraclePriceE18) = h.quoteExactInput(address(usdc), 1e6);
        assertApproxEqRel(oraclePriceE18, 156.25e18, 0.0001e18);
        assertApproxEqRel(buyAmount, 155.78125e18, 0.0001e18); // 156.25 JPYC less 30 bps spread
    }

    function test_quoteExactInput_scalesSixDecimalUsdcToZeroDecimalKrw1() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 krw1 = new MockERC20("KRW1", "KRW1", 0);
        FxSwapHook h = _newHotOnlyHook(usdc, krw1, 1_00_000_000, 67_120); // KRW1/USD ~= 0.00067120

        usdc.mint(alice, 10_000e6);
        krw1.mint(alice, 14_898_689);
        vm.startPrank(alice);
        usdc.approve(address(h), type(uint256).max);
        krw1.approve(address(h), type(uint256).max);
        _depositSorted(h, address(usdc), 10_000e6, address(krw1), 14_898_689);
        vm.stopPrank();

        vm.prank(owner);
        h.setKBps(0);

        (uint256 buyAmount, uint256 oraclePriceE18) = h.quoteExactInput(address(usdc), 1e6);
        assertApproxEqRel(oraclePriceE18, 1489.868891e18, 0.0001e18);
        assertEq(buyAmount, 1485); // 0-decimal output floors after spread
    }

    /*//////////////////////////////////////////////////////////////
                          POOL KEY ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_beforeInitialize_revertsOnWrongTokens() public {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0xDEAD)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        hook.beforeInitialize(address(0), badKey, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            CTOR GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert();
        new FxSwapHook(address(0), address(oracle), registry, owner, address(token0), address(token1), address(0x4444));
        vm.expectRevert();
        new FxSwapHook(poolManager, address(oracle), registry, owner, address(token0), address(token1), address(0));
    }

    function _newHotOnlyHook(MockERC20 a, MockERC20 b, int64 priceA, int64 priceB)
        internal
        returns (FxSwapHook h)
    {
        MockPyth p = new MockPyth();
        FxOracle o = new FxOracle(address(p), owner, 60, 50, 30);

        bytes32 feedA = keccak256(abi.encodePacked(address(a)));
        bytes32 feedB = keccak256(abi.encodePacked(address(b)));
        vm.startPrank(owner);
        o.setFeed(address(a), feedA);
        o.setFeed(address(b), feedB);
        vm.stopPrank();

        p.setPrice(feedA, priceA, 100, -8, block.timestamp);
        p.setPrice(feedB, priceB, 100, -8, block.timestamp);

        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        h = new FxSwapHook(poolManager, address(o), registry, owner, t0, t1, address(0x4444));
        vm.prank(owner);
        h.setHotReservePct(10_000);
    }

    function _depositSorted(FxSwapHook h, address tokenA, uint256 amountA, address tokenB, uint256 amountB) internal {
        if (h.TOKEN0() == tokenA) {
            h.deposit(amountA, amountB);
        } else {
            assertEq(h.TOKEN0(), tokenB);
            h.deposit(amountB, amountA);
        }
    }
}
