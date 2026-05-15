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
        uint256 total = hot + supplied;
        if (total == 0) return;

        uint256 targetHot = (total * hook.hotReservePct()) / 10_000;
        assertLe(hot, targetHot + 2, "hot reserve above target");
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
