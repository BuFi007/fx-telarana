// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IMorpho, MarketParams as MorphoMarketParams, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {FxV4RouterHarness} from "./utils/FxV4RouterHarness.sol";

contract FxSwapHookInvariantHandler {
    FxSwapHook public immutable hook;
    FxV4RouterHarness public immutable router;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    MockPyth public immutable pyth;
    bytes32 public immutable movingFeed;
    PoolKey public key;

    uint256 public immutable minDeposit0;
    uint256 public immutable maxDeposit0;
    uint256 public immutable minDeposit1;
    uint256 public immutable maxDeposit1;
    uint256 public immutable maxSwap0;
    uint256 public immutable maxSwap1;

    uint256 public movingFeedPrice;

    constructor(
        FxSwapHook hook_,
        FxV4RouterHarness router_,
        MockERC20 token0_,
        MockERC20 token1_,
        MockPyth pyth_,
        bytes32 movingFeed_,
        PoolKey memory key_,
        uint256 movingFeedPrice_,
        uint256 minDeposit0_,
        uint256 maxDeposit0_,
        uint256 minDeposit1_,
        uint256 maxDeposit1_,
        uint256 maxSwap0_,
        uint256 maxSwap1_
    ) {
        hook = hook_;
        router = router_;
        token0 = token0_;
        token1 = token1_;
        pyth = pyth_;
        movingFeed = movingFeed_;
        key = key_;
        movingFeedPrice = movingFeedPrice_;
        minDeposit0 = minDeposit0_;
        maxDeposit0 = maxDeposit0_;
        minDeposit1 = minDeposit1_;
        maxDeposit1 = maxDeposit1_;
        maxSwap0 = maxSwap0_;
        maxSwap1 = maxSwap1_;

        token0.approve(address(hook_), type(uint256).max);
        token1.approve(address(hook_), type(uint256).max);
        token0.approve(address(router_), type(uint256).max);
        token1.approve(address(router_), type(uint256).max);
    }

    function deposit(uint256 amount0, uint256 amount1) external {
        amount0 = _bound(amount0, minDeposit0, maxDeposit0);
        amount1 = _bound(amount1, minDeposit1, maxDeposit1);

        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        hook.deposit(amount0, amount1);
    }

    function redeem(uint256 rawShares) external {
        uint256 shares = hook.sharesOf(address(this));
        if (shares == 0) return;

        shares = _bound(rawShares, 1, shares);
        hook.redeem(shares);
    }

    function swap0For1(uint256 rawAmountIn) external {
        if (hook.totalShares() <= hook.MINIMUM_LIQUIDITY()) return;

        uint256 amountIn = _bound(rawAmountIn, 1, maxSwap0);
        (uint256 quoted,) = hook.quoteExactInput(address(token0), amountIn);
        if (quoted == 0) return;

        token0.mint(address(this), amountIn);
        try router.swapExactInputSingle(key, true, amountIn, 1, address(this)) returns (uint256) {} catch {}
    }

    function swap1For0(uint256 rawAmountIn) external {
        if (hook.totalShares() <= hook.MINIMUM_LIQUIDITY()) return;

        uint256 amountIn = _bound(rawAmountIn, 1, maxSwap1);
        (uint256 quoted,) = hook.quoteExactInput(address(token1), amountIn);
        if (quoted == 0) return;

        token1.mint(address(this), amountIn);
        try router.swapExactInputSingle(key, false, amountIn, 1, address(this)) returns (uint256) {} catch {}
    }

    function moveOracle(uint256 rawMoveBps, bool up) external {
        uint256 moveBps = _bound(rawMoveBps, 1, 1_500);
        uint256 nextPrice =
            up ? (movingFeedPrice * (10_000 + moveBps)) / 10_000 : (movingFeedPrice * (10_000 - moveBps)) / 10_000;

        if (nextPrice == 0 || nextPrice > uint256(uint64(type(int64).max))) return;
        movingFeedPrice = nextPrice;
        pyth.setPrice(movingFeed, int64(uint64(nextPrice)), 100, -8, block.timestamp);
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return min + (x % (max - min + 1));
        return x;
    }
}

/// @notice Stateful safety checks for the Morpho-backed v4 hook path.
///         The handler runs LP deposits/redeems, real v4 router settlement
///         swaps in both directions, and oracle moves. Invariants assert that:
///         1. hook Morpho-share bookkeeping equals Morpho's position book,
///         2. post-rebalance hot reserves never sit above the configured target,
///         3. router/PoolManager never retain pair tokens after settlement.
contract FxSwapHookInvariantTest is Test {
    using MarketParamsLib for MorphoMarketParams;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV = 0.86e18;
    uint160 internal constant Q96 = 79228162514264337593543950336;

    bytes32 internal constant FEED_USDC = keccak256("USDC");
    bytes32 internal constant FEED_JPYC = keccak256("JPYC");
    uint256 internal constant PRICE_USDC = 1_00_000_000;
    uint256 internal constant PRICE_JPYC_USD_INVERTED = 156_25_000_000;

    address internal owner = address(this);
    address internal lp = address(0xBEEF);

    MockERC20 internal usdc;
    MockERC20 internal jpyc;
    MockPyth internal pyth;
    FxOracle internal oracle;
    FxMarketRegistry internal registry;
    IMorpho internal morpho;
    address internal irm;
    PoolManager internal poolManager;
    FxV4RouterHarness internal router;
    FxSwapHook internal hook;
    PoolKey internal key;
    MorphoMarketParams internal usdcMarket;
    MorphoMarketParams internal jpycMarket;

    function setUp() public {
        if (
            !vm.isFile("out/Morpho.sol/Morpho.json") || !vm.isFile("out/IrmMock.sol/IrmMock.json")
                || bytes(_fxSwapHookArtifact()).length == 0
        ) {
            vm.skip(true, "run forge build --force test/MorphoArtifacts.t.sol before hook invariants");
        }

        usdc = new MockERC20("USD Coin", "USDC", 6);
        jpyc = new MockERC20("JPYC", "JPYC", 18);
        pyth = new MockPyth();
        oracle = new FxOracle(address(pyth), owner, 600, 100, 100);

        oracle.setPythFeedConfig(address(usdc), FEED_USDC, false);
        oracle.setPythFeedConfig(address(jpyc), FEED_JPYC, true);
        pyth.setPrice(FEED_USDC, int64(uint64(PRICE_USDC)), 100, -8, block.timestamp);
        pyth.setPrice(FEED_JPYC, int64(uint64(PRICE_JPYC_USD_INVERTED)), 100, -8, block.timestamp);

        morpho = IMorpho(deployCode("out/Morpho.sol/Morpho.json", abi.encode(owner)));
        irm = deployCode("out/IrmMock.sol/IrmMock.json");
        morpho.enableIrm(irm);
        morpho.enableLltv(LLTV);

        registry = new FxMarketRegistry(address(morpho), owner);
        _createMarkets();

        poolManager = new PoolManager(owner);
        router = new FxV4RouterHarness(IPoolManager(address(poolManager)));
        hook = _deployHook();
        key = _poolKey(address(hook));
        poolManager.initialize(key, Q96);

        _seedHook();
        _targetHandler();
    }

    function invariant_morphoShareBookkeepingMatchesMorpho() public view {
        _assertMorphoShareBook(address(usdc), usdcMarket);
        _assertMorphoShareBook(address(jpyc), jpycMarket);
    }

    function invariant_hotReserveDoesNotExceedTargetAfterRebalance() public view {
        _assertHotReserveAtTarget(address(usdc), usdcMarket);
        _assertHotReserveAtTarget(address(jpyc), jpycMarket);
    }

    function invariant_routerAndPoolManagerDoNotRetainPairTokens() public view {
        assertEq(usdc.balanceOf(address(poolManager)), 0, "PoolManager retained USDC");
        assertEq(jpyc.balanceOf(address(poolManager)), 0, "PoolManager retained JPYC");
        assertEq(usdc.balanceOf(address(router)), 0, "router retained USDC");
        assertEq(jpyc.balanceOf(address(router)), 0, "router retained JPYC");
    }

    /*//////////////////////////////////////////////////////////////
              PROTOCOL FEE SLEEVE — INTEGRATION (Phase 2.7 #3)
    //////////////////////////////////////////////////////////////*/

    function test_protocolFee_accruesOnSwap() public {
        hook.setProtocolFeeBps(2_000); // 20% of swap fee → treasury

        address trader = address(0x111111);
        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address inToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        address feeToken = zeroForOne ? hook.TOKEN1() : hook.TOKEN0();
        uint256 amountIn = inToken == address(usdc) ? 100e6 : 10_000e18;

        MockERC20(inToken).mint(trader, amountIn);
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        router.swapExactInputSingle(key, zeroForOne, amountIn, 1, trader);
        vm.stopPrank();

        uint256 protoFee = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGt(protoFee, 0, "no fee accrued");

        // Sanity: protocol fee can never exceed total assets of that token
        // (hot + Morpho-supplied). Bound using Morpho's expected-assets view.
        uint256 supplied = MorphoBalancesLib.expectedSupplyAssets(
            morpho, feeToken == address(usdc) ? usdcMarket : jpycMarket, address(hook)
        );
        uint256 totalAssets = IERC20(feeToken).balanceOf(address(hook)) + supplied;
        assertLe(protoFee, totalAssets, "fee exceeds total assets");
    }

    function test_protocolFee_claimableByTreasury() public {
        address treasuryAddr = address(0xC0FFEE);
        hook.setTreasury(treasuryAddr);
        hook.setProtocolFeeBps(2_500); // 25%

        address trader = address(0x222222);
        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address inToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        address feeToken = zeroForOne ? hook.TOKEN1() : hook.TOKEN0();
        uint256 amountIn = inToken == address(usdc) ? 200e6 : 20_000e18;

        MockERC20(inToken).mint(trader, amountIn);
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        router.swapExactInputSingle(key, zeroForOne, amountIn, 1, trader);
        vm.stopPrank();

        uint256 protoFeeBefore = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGt(protoFeeBefore, 0);

        // Treasury withdraws full accrued amount.
        vm.prank(treasuryAddr);
        hook.claimProtocolFees(feeToken, treasuryAddr, protoFeeBefore);

        uint256 protoFeeAfter = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertEq(protoFeeAfter, 0, "protocol fee balance not drained");
        assertEq(MockERC20(feeToken).balanceOf(treasuryAddr), protoFeeBefore, "treasury did not receive funds");
    }

    function test_protocolFee_remainsClaimableAfterAdversarialDrainAttempt() public {
        // Codex-2.7 finding #2 regression: previously, accrued fees were still
        // in `_totalAssets` for swap reserves, so adversarial post-accrual
        // swaps could drain past the claimable balance, bricking treasury
        // withdrawal. The patch routes swaps through `_tradableAssets`.
        address treasuryAddr = address(0xC0FFEE);
        hook.setTreasury(treasuryAddr);
        hook.setProtocolFeeBps(5_000); // 50% — the maximum, biggest fee per swap

        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address inToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        address feeToken = zeroForOne ? hook.TOKEN1() : hook.TOKEN0();

        // Build up a meaningful protocol-fee balance with several swaps.
        address attacker = address(0xBADBAD);
        uint256 perSwap = inToken == address(usdc) ? 200e6 : 20_000e18;
        for (uint256 i = 0; i < 5; ++i) {
            MockERC20(inToken).mint(attacker, perSwap);
            vm.startPrank(attacker);
            MockERC20(inToken).approve(address(router), type(uint256).max);
            router.swapExactInputSingle(key, zeroForOne, perSwap, 1, attacker);
            vm.stopPrank();
        }

        uint256 feeBefore = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGt(feeBefore, 0, "no fee accrued");

        // Attacker now tries to drain the fee-side reserves with the OPPOSITE
        // swap direction (output side = fee-bearing token). With the patch,
        // tradable reserves exclude the fee sleeve, so this swap either reverts
        // or returns less output — but in NO case can it eat into the fee
        // balance.
        uint256 attackerBudget = inToken == address(usdc) ? 1_000e6 : 100_000e18;
        MockERC20(inToken).mint(attacker, attackerBudget);
        vm.startPrank(attacker);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        // amountOutMinimum=1 so the call is permissive; we only care that the
        // fee balance is untouched.
        try router.swapExactInputSingle(key, zeroForOne, attackerBudget, 1, attacker) returns (uint256) {}
        catch {} // OK if it reverts InsufficientLiquidity; either way the fee survives.
        vm.stopPrank();

        // Treasury can still claim the full pre-attack fee balance, even
        // though the attack swap may have grown the sleeve further.
        uint256 feeAfterAttack = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGe(feeAfterAttack, feeBefore, "attack swap should not reduce protocol fee");

        vm.prank(treasuryAddr);
        hook.claimProtocolFees(feeToken, treasuryAddr, feeBefore);
        assertEq(MockERC20(feeToken).balanceOf(treasuryAddr), feeBefore, "treasury did not receive full pre-attack fee");
        // Whatever new fee was generated by the attack swap remains claimable too.
        uint256 feeRemaining = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertEq(feeRemaining, feeAfterAttack - feeBefore, "claim drained more than requested");
    }

    function test_protocolFee_hotSleeveIsPreservedAcrossOutputSwap() public {
        // Codex-2.7 finding #3 regression: previously, the JIT-withdraw
        // decision compared `amountOut` to RAW hot balance — which includes
        // the protocol-fee sleeve. A swap that fits inside hot could pay
        // output from fee-bearing tokens, making the treasury claim depend
        // on Morpho liquidity later. The patch gates the withdraw on
        // `hot − outputFee`. Verify by accruing fees, then running an
        // output-side swap that *would* fit in raw hot, and checking that
        // the hot fee balance is at least as large as protocolFee afterwards.
        hook.setProtocolFeeBps(5_000);

        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address inToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        address feeToken = zeroForOne ? hook.TOKEN1() : hook.TOKEN0();

        address trader = address(0xCAFE99);
        uint256 perSwap = inToken == address(usdc) ? 100e6 : 10_000e18;
        for (uint256 i = 0; i < 3; ++i) {
            MockERC20(inToken).mint(trader, perSwap);
            vm.startPrank(trader);
            MockERC20(inToken).approve(address(router), type(uint256).max);
            router.swapExactInputSingle(key, zeroForOne, perSwap, 1, trader);
            vm.stopPrank();
        }

        uint256 fee = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGt(fee, 0);

        // Now run another swap of the same direction. Even if the requested
        // output fits in raw hot, the JIT-withdraw must trigger so the fee
        // tokens remain in hot custody.
        MockERC20(inToken).mint(trader, perSwap);
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        router.swapExactInputSingle(key, zeroForOne, perSwap, 1, trader);
        vm.stopPrank();

        // Post-swap hot balance must still cover the protocol fee.
        uint256 feeAfter = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        uint256 hotAfter = MockERC20(feeToken).balanceOf(address(hook));
        // The patch guarantees swap output draws from Morpho once it would
        // bite into the fee sleeve, so hot ≥ fee at all times.
        assertGe(hotAfter, feeAfter, "swap consumed hot fee sleeve");
    }

    function test_protocolFee_hotSleeveSurvivesOppositeDirectionRebalance() public {
        // Codex-2.7 round 2 finding A: previously, fees accrued on token0 (via
        // !zeroForOne swaps) sat in hot; a subsequent zeroForOne swap pulled
        // token0 from the user (input side) and triggered afterSwap →
        // _rebalanceToken(token0), which supplied "excess hot" to Morpho,
        // moving the fee sleeve out of hot custody. Verify that fees on the
        // CURRENT input-side token are NOT rehypothecated.
        hook.setProtocolFeeBps(5_000);

        // Step 1: accrue fees on token0 by selling token1.
        bool t0IsUsdc = hook.TOKEN0() == address(usdc);
        bool firstZeroForOne = !t0IsUsdc ? true : false;  // ensure output = token0
        // Actually simpler: figure direction so output == TOKEN0.
        // sellBase (zeroForOne) = output is TOKEN1; sellQuote (!zeroForOne) = output is TOKEN0.
        firstZeroForOne = false;
        address t0InToken = firstZeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        uint256 firstAmount = t0InToken == address(usdc) ? 200e6 : 20_000e18;

        address trader = address(0xDEC0DE);
        MockERC20(t0InToken).mint(trader, firstAmount * 3);
        vm.startPrank(trader);
        MockERC20(t0InToken).approve(address(router), type(uint256).max);
        for (uint256 i = 0; i < 3; ++i) {
            router.swapExactInputSingle(key, firstZeroForOne, firstAmount, 1, trader);
        }
        vm.stopPrank();

        uint256 fee0 = hook.protocolFee0();
        assertGt(fee0, 0, "fee0 did not accrue");

        // Step 2: now perform an OPPOSITE swap whose input side is TOKEN0.
        // afterSwap → _rebalanceToken(TOKEN0). With the patch, hot[token0]
        // must remain >= protocolFee0.
        bool secondZeroForOne = true; // sells TOKEN0
        address t0InTokenSecond = hook.TOKEN0();
        uint256 secondAmount = t0InTokenSecond == address(usdc) ? 50e6 : 5_000e18;
        MockERC20(t0InTokenSecond).mint(trader, secondAmount);
        vm.startPrank(trader);
        MockERC20(t0InTokenSecond).approve(address(router), type(uint256).max);
        router.swapExactInputSingle(key, secondZeroForOne, secondAmount, 1, trader);
        vm.stopPrank();

        uint256 hot0After = IERC20(hook.TOKEN0()).balanceOf(address(hook));
        uint256 fee0After = hook.protocolFee0();
        assertGe(hot0After, fee0After, "rebalance consumed protocol fee sleeve");
    }

    function test_protocolFee_hotSleeveSurvivesLpRedeem() public {
        // Codex-2.7 round 2 finding B: redeem's _ensureHotBalance previously
        // used raw hot, so an LP redemption could draw from fee-bearing
        // tokens. Patch routes through _ensureHotTradable. Verify hot[fee
        // token] >= protocolFee after LP redeem.
        hook.setProtocolFeeBps(5_000);

        // Accrue fees on the JPYC side via zeroForOne swaps (sell base, output = quote).
        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address inToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        address feeToken = zeroForOne ? hook.TOKEN1() : hook.TOKEN0();
        uint256 perSwap = inToken == address(usdc) ? 300e6 : 30_000e18;

        address trader = address(0xDEAD11);
        MockERC20(inToken).mint(trader, perSwap * 3);
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        for (uint256 i = 0; i < 3; ++i) {
            router.swapExactInputSingle(key, zeroForOne, perSwap, 1, trader);
        }
        vm.stopPrank();

        uint256 fee = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGt(fee, 0);

        // LP redeems most of their stake; hot[feeToken] must still cover the fee.
        uint256 lpShares = hook.sharesOf(lp);
        vm.prank(lp);
        hook.redeem(lpShares / 2);

        uint256 hotFeeAfter = IERC20(feeToken).balanceOf(address(hook));
        uint256 feeAfter = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGe(hotFeeAfter, feeAfter, "LP redeem consumed protocol fee sleeve");
    }

    function test_protocolFee_lateLpEntryIsNotDilutedByAccruedFees() public {
        // Codex-2.7 round 3 finding: previously, deposit used _totalAssets
        // (which includes accrued protocol fees) as the share denominator,
        // while redeem subtracted protocolFee before pro-rating. A late LP
        // would mint at an inflated denominator — implicitly underwriting
        // treasury fees they're not entitled to. Patch routes deposit
        // through _tradableAssets for symmetry. Verify: an LP who deposits
        // AFTER fees accrue gets the same fair value back on immediate redeem.
        hook.setProtocolFeeBps(5_000);

        // Accrue fees on TOKEN0 side via opposite-direction swaps.
        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address swapInToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        uint256 perSwap = swapInToken == address(usdc) ? 200e6 : 20_000e18;

        address trader = address(0xCC0FFEE);
        MockERC20(swapInToken).mint(trader, perSwap * 3);
        vm.startPrank(trader);
        MockERC20(swapInToken).approve(address(router), type(uint256).max);
        for (uint256 i = 0; i < 3; ++i) {
            router.swapExactInputSingle(key, zeroForOne, perSwap, 1, trader);
        }
        vm.stopPrank();

        // Late LP must deposit at the *current tradable ratio* to avoid the
        // unrelated AMM-style dust loss from min(s0,s1) clamping. Compute the
        // tradable amounts (totalAssets minus protocol fee) via public state.
        uint256 hot0   = IERC20(hook.TOKEN0()).balanceOf(address(hook));
        uint256 hot1   = IERC20(hook.TOKEN1()).balanceOf(address(hook));
        uint256 supply0 = MorphoBalancesLib.expectedSupplyAssets(
            morpho, hook.TOKEN0() == address(usdc) ? usdcMarket : jpycMarket, address(hook)
        );
        uint256 supply1 = MorphoBalancesLib.expectedSupplyAssets(
            morpho, hook.TOKEN1() == address(usdc) ? usdcMarket : jpycMarket, address(hook)
        );
        uint256 trad0 = hot0 + supply0 - hook.protocolFee0();
        uint256 trad1 = hot1 + supply1 - hook.protocolFee1();

        address lateLp = address(0xDD11EE);
        // Pick a small deposit on TOKEN0 side, scale TOKEN1 to match the
        // tradable ratio so neither side clamps the share grant.
        uint256 lateDeposit0 = trad0 / 100;            // 1% of tradable TOKEN0
        uint256 lateDeposit1 = (trad1 * lateDeposit0) / trad0;
        MockERC20(hook.TOKEN0()).mint(lateLp, lateDeposit0);
        MockERC20(hook.TOKEN1()).mint(lateLp, lateDeposit1);
        vm.startPrank(lateLp);
        MockERC20(hook.TOKEN0()).approve(address(hook), type(uint256).max);
        MockERC20(hook.TOKEN1()).approve(address(hook), type(uint256).max);
        uint256 lateShares = hook.deposit(lateDeposit0, lateDeposit1);
        (uint256 out0, uint256 out1) = hook.redeem(lateShares);
        vm.stopPrank();

        // After the symmetric-deposit patch, deposit→immediate-redeem
        // round-trips ≥99.5%. Without the patch, treasury fees would have
        // diluted the late LP's share, putting recovery well below 99%.
        assertGe(out0 * 1000, lateDeposit0 * 995, "late LP TOKEN0 under-redeemed");
        assertGe(out1 * 1000, lateDeposit1 * 995, "late LP TOKEN1 under-redeemed");
    }

    function test_syncThenSwap_capturesDonationIntoLpEquity() public {
        // Phase 2.7 ships DODO V2 reference behavior: balanced donations
        // are NOT auto-absorbed. Calling `sync()` after a donation snaps
        // the equilibrium targets so the donation backs LP value. Verify
        // the LP's tradable claim grows after sync().
        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address inToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();

        // Balanced donation: ~5% of seed each side.
        address donor = address(0xDEDE01);
        uint256 donate0 = hook.TOKEN0() == address(usdc) ? 500e6 : 75_000e18;
        uint256 donate1 = hook.TOKEN1() == address(usdc) ? 500e6 : 75_000e18;
        MockERC20(hook.TOKEN0()).mint(donor, donate0);
        MockERC20(hook.TOKEN1()).mint(donor, donate1);
        vm.startPrank(donor);
        MockERC20(hook.TOKEN0()).transfer(address(hook), donate0);
        MockERC20(hook.TOKEN1()).transfer(address(hook), donate1);
        vm.stopPrank();

        uint256 b0Before = hook.baseTargetE18();
        uint256 q0Before = hook.quoteTargetE18();
        // Owner-gated capture (test contract is the owner). Read current
        // tradable assets via the public view, scale to 1e18, pass as
        // expected with a tight 50bps tolerance.
        uint8 dec0 = MockERC20(hook.TOKEN0()).decimals();
        uint8 dec1 = MockERC20(hook.TOKEN1()).decimals();
        uint256 b0Expected = hook.tradableAssets(hook.TOKEN0()) * (10 ** (18 - dec0));
        uint256 q0Expected = hook.tradableAssets(hook.TOKEN1()) * (10 ** (18 - dec1));
        hook.sync(b0Expected, q0Expected, 50);
        assertGt(hook.baseTargetE18(), b0Before, "sync did not grow baseTarget");
        assertGt(hook.quoteTargetE18(), q0Before, "sync did not grow quoteTarget");

        // After sync, the curve sees the donation as part of equilibrium.
        // A swap quotes against the larger pool with proper inventory math.
        address trader = address(0xBEAF01);
        uint256 perSwap = inToken == address(usdc) ? 50e6 : 5_000e18;
        MockERC20(inToken).mint(trader, perSwap);
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        uint256 amountOut = router.swapExactInputSingle(key, zeroForOne, perSwap, 1, trader);
        vm.stopPrank();
        assertGt(amountOut, 0);
    }

    function test_lpRedeem_excludesProtocolFee() public {
        hook.setProtocolFeeBps(3_000); // 30%

        // Trader generates fees on the JPYC side.
        address trader = address(0x333333);
        bool zeroForOne = hook.TOKEN0() == address(usdc);
        address inToken = zeroForOne ? hook.TOKEN0() : hook.TOKEN1();
        address feeToken = zeroForOne ? hook.TOKEN1() : hook.TOKEN0();
        uint256 amountIn = inToken == address(usdc) ? 300e6 : 30_000e18;

        MockERC20(inToken).mint(trader, amountIn);
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(router), type(uint256).max);
        router.swapExactInputSingle(key, zeroForOne, amountIn, 1, trader);
        vm.stopPrank();

        uint256 feeAccrued = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertGt(feeAccrued, 0);

        // LP redeems all their shares. Their slice of the fee-token side must be
        // less than (totalAssets * shares / totalShares) by exactly the deducted
        // protocolFee share.
        uint256 lpShares = hook.sharesOf(lp);
        uint256 expectedFeeSideBefore = MockERC20(feeToken).balanceOf(lp);

        vm.prank(lp);
        hook.redeem(lpShares);

        uint256 feeSideReceived = MockERC20(feeToken).balanceOf(lp) - expectedFeeSideBefore;
        // After LP exits, protocolFee1 (or 0) should be untouched.
        uint256 feeStillAccrued = zeroForOne ? hook.protocolFee1() : hook.protocolFee0();
        assertEq(feeStillAccrued, feeAccrued, "LP redemption drained protocol fee");
        // LP received fee-side amount must be positive but exclude the sleeve.
        assertGt(feeSideReceived, 0);
    }

    function _createMarkets() internal {
        MorphoOracleAdapter adapterJpycLoan = new MorphoOracleAdapter(address(oracle), address(jpyc), address(usdc));
        MorphoOracleAdapter adapterUsdcLoan = new MorphoOracleAdapter(address(oracle), address(usdc), address(jpyc));

        IFxMarketRegistry.MarketParams memory jpycLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(jpyc),
            collateralToken: address(usdc),
            oracle: address(adapterJpycLoan),
            irm: irm,
            lltv: LLTV
        });
        IFxMarketRegistry.MarketParams memory usdcLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(usdc),
            collateralToken: address(jpyc),
            oracle: address(adapterUsdcLoan),
            irm: irm,
            lltv: LLTV
        });

        registry.createAndRegisterMarket(jpycLoan);
        registry.createAndRegisterMarket(usdcLoan);
        jpycMarket = _toMorphoParams(jpycLoan);
        usdcMarket = _toMorphoParams(usdcLoan);
    }

    function _seedHook() internal {
        usdc.mint(lp, 10_000e6);
        jpyc.mint(lp, 1_562_500e18);

        vm.startPrank(lp);
        usdc.approve(address(hook), type(uint256).max);
        jpyc.approve(address(hook), type(uint256).max);
        _depositSorted(hook, address(usdc), 10_000e6, address(jpyc), 1_562_500e18);
        vm.stopPrank();

        assertGt(hook.morphoShares(address(usdc)), 0, "seed did not supply USDC to Morpho");
        assertGt(hook.morphoShares(address(jpyc)), 0, "seed did not supply JPYC to Morpho");
    }

    function _targetHandler() internal {
        MockERC20 token0 = MockERC20(hook.TOKEN0());
        MockERC20 token1 = MockERC20(hook.TOKEN1());
        (uint256 minDeposit0, uint256 maxDeposit0, uint256 maxSwap0) = _boundsFor(address(token0));
        (uint256 minDeposit1, uint256 maxDeposit1, uint256 maxSwap1) = _boundsFor(address(token1));
        (bytes32 movingFeed, uint256 movingPrice) =
            address(token0) == address(usdc) ? (FEED_USDC, PRICE_USDC) : (FEED_JPYC, PRICE_JPYC_USD_INVERTED);

        FxSwapHookInvariantHandler handler = new FxSwapHookInvariantHandler({
            hook_: hook,
            router_: router,
            token0_: token0,
            token1_: token1,
            pyth_: pyth,
            movingFeed_: movingFeed,
            key_: key,
            movingFeedPrice_: movingPrice,
            minDeposit0_: minDeposit0,
            maxDeposit0_: maxDeposit0,
            minDeposit1_: minDeposit1,
            maxDeposit1_: maxDeposit1,
            maxSwap0_: maxSwap0,
            maxSwap1_: maxSwap1
        });

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = FxSwapHookInvariantHandler.deposit.selector;
        selectors[1] = FxSwapHookInvariantHandler.redeem.selector;
        selectors[2] = FxSwapHookInvariantHandler.swap0For1.selector;
        selectors[3] = FxSwapHookInvariantHandler.swap1For0.selector;
        selectors[4] = FxSwapHookInvariantHandler.moveOracle.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _assertMorphoShareBook(address token, MorphoMarketParams memory marketParams) internal view {
        Position memory position = morpho.position(marketParams.id(), address(hook));
        assertEq(hook.morphoShares(token), position.supplyShares, "hook/Morpho supply share drift");
    }

    function _assertHotReserveAtTarget(address token, MorphoMarketParams memory marketParams) internal view {
        uint256 hot = IERC20(token).balanceOf(address(hook));
        uint256 supplied = morpho.expectedSupplyAssets(marketParams, address(hook));
        uint256 fee = token == hook.TOKEN0() ? hook.protocolFee0() : hook.protocolFee1();

        // Production rebalance excludes the protocol-fee sleeve from
        // tradable hot/total. Mirror that here so the invariant stays
        // consistent with the actual contract behavior — otherwise we'd
        // flag a healthy "fees-staying-hot" state as a violation.
        uint256 hotTradable = hot > fee ? hot - fee : 0;
        uint256 tradableTotal = hotTradable + supplied;
        if (tradableTotal == 0) {
            // Still enforce the hot-fee preservation invariant on its own.
            assertGe(hot, fee, "hot reserve dropped below protocol fee");
            return;
        }

        uint256 targetHot = (tradableTotal * hook.hotReservePct()) / 10_000;
        assertLe(hotTradable, targetHot + 2, "tradable hot reserve above target");
        // Hot custody must always cover the accrued fee sleeve (Phase 2.7 #3).
        assertGe(hot, fee, "hot reserve dropped below protocol fee");
    }

    function _boundsFor(address token) internal view returns (uint256 minDeposit, uint256 maxDeposit, uint256 maxSwap) {
        if (token == address(usdc)) return (1e6, 100e6, 250e6);
        return (100e18, 10_000e18, 40_000e18);
    }

    function _deployHook() internal returns (FxSwapHook deployedHook) {
        (address token0, address token1) = _sort(address(usdc), address(jpyc));
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(address(poolManager), address(oracle), address(registry), owner, token0, token1, address(morpho))
        );
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected,) = HookMiner.find(address(this), flags, creationCode, 500_000);
        deployCodeTo(
            _fxSwapHookArtifact(),
            abi.encode(
                address(poolManager), address(oracle), address(registry), owner, token0, token1, address(morpho)
            ),
            expected
        );
        deployedHook = FxSwapHook(expected);
    }

    function _poolKey(address hookAddress) internal view returns (PoolKey memory poolKey) {
        (address token0, address token1) = _sort(address(usdc), address(jpyc));
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
    }

    function _depositSorted(FxSwapHook targetHook, address tokenA, uint256 amountA, address tokenB, uint256 amountB)
        internal
    {
        if (targetHook.TOKEN0() == tokenA) {
            targetHook.deposit(amountA, amountB);
        } else {
            assertEq(targetHook.TOKEN0(), tokenB);
            targetHook.deposit(amountB, amountA);
        }
    }

    function _toMorphoParams(IFxMarketRegistry.MarketParams memory p)
        internal
        pure
        returns (MorphoMarketParams memory)
    {
        return MorphoMarketParams({
            loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv
        });
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function _fxSwapHookArtifact() internal view returns (string memory) {
        if (vm.isFile("out/FxSwapHook.sol/FxSwapHook.json")) return "out/FxSwapHook.sol/FxSwapHook.json";
        if (vm.isFile("out/FxSwapHook.sol/FxSwapHook.0.8.26.json")) {
            return "out/FxSwapHook.sol/FxSwapHook.0.8.26.json";
        }
        if (vm.isFile("out/FxSwapHook.sol/FxSwapHook.0.8.28.json")) {
            return "out/FxSwapHook.sol/FxSwapHook.0.8.28.json";
        }
        return "";
    }
}
