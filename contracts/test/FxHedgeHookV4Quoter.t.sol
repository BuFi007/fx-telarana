// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxHedgeHook} from "../src/hub/FxHedgeHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";

/// @notice Local diagnostic for official Uniswap v4 quoter compatibility.
///         FxHedgeHook is an observer hook with no custom deltas, so exact-input
///         and exact-output quotes should behave like ordinary v4 pool quotes.
contract FxHedgeHookV4QuoterTest is Test {
    using PoolIdLibrary for PoolKey;

    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;
    uint160 internal constant Q96 = 79228162514264337593543950336;

    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:TEST/USDC");
    bytes32 internal constant PYTH_FEED_ID = keccak256("TEST/USD");

    address internal owner = address(this);
    address internal admin = address(this);
    uint256 internal threshold = 10_000_000e18;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal currency0Token;
    MockERC20 internal currency1Token;
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal positionManager;
    IV4Quoter internal quoter;
    FxHedgeHook internal hook;
    PoolKey internal key;
    bytes32 internal poolId;
    address internal hedgeToken;

    function setUp() public {
        tokenA = new MockERC20("USD Coin", "USDC", 18);
        tokenB = new MockERC20("Hedge Token", "HEDGE", 18);
        (currency0Token, currency1Token) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        poolManager = new PoolManager(owner);
        positionManager = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        quoter = new V4Quoter(IPoolManager(address(poolManager)));
        hook = _deployHook();

        key = PoolKey({
            currency0: Currency.wrap(address(currency0Token)),
            currency1: Currency.wrap(address(currency1Token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = PoolId.unwrap(key.toId());
        hedgeToken = address(currency1Token);

        hook.configurePool(key, MARKET_ID, hedgeToken, 18, PYTH_FEED_ID, threshold, true);
        poolManager.initialize(key, Q96);
        _seedLiquidity();
    }

    function test_v4QuoterQuotesFxHedgeHookExactInput() public {
        int256 exposureBefore = hook.poolExposureE18(poolId);
        int256 hedgeBefore = hook.poolHedgeSizeE18(poolId);

        (uint256 amountOut, uint256 gasEstimate) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: true,
                exactAmount: uint128(1e18),
                hookData: ""
            })
        );

        assertGt(amountOut, 0, "expected a nonzero quote");
        assertGt(gasEstimate, 50_000, "expected nontrivial quoter gas estimate");
        assertEq(hook.poolExposureE18(poolId), exposureBefore, "quoter persisted exposure");
        assertEq(hook.poolHedgeSizeE18(poolId), hedgeBefore, "quoter persisted hedge");
    }

    function test_v4QuoterQuotesFxHedgeHookExactOutput() public {
        int256 exposureBefore = hook.poolExposureE18(poolId);
        int256 hedgeBefore = hook.poolHedgeSizeE18(poolId);

        (uint256 amountIn, uint256 gasEstimate) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: true,
                exactAmount: uint128(1e18),
                hookData: ""
            })
        );

        assertGt(amountIn, 0, "expected a nonzero exact-output quote");
        assertGt(gasEstimate, 50_000, "expected nontrivial quoter gas estimate");
        assertEq(hook.poolExposureE18(poolId), exposureBefore, "quoter persisted exposure");
        assertEq(hook.poolHedgeSizeE18(poolId), hedgeBefore, "quoter persisted hedge");
    }

    function _seedLiquidity() internal {
        currency0Token.mint(address(this), 1_000_000e18);
        currency1Token.mint(address(this), 1_000_000e18);
        currency0Token.approve(address(positionManager), type(uint256).max);
        currency1Token.approve(address(positionManager), type(uint256).max);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            Q96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            1_000_000e18,
            1_000_000e18
        );
        positionManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _deployHook() internal returns (FxHedgeHook deployedHook) {
        bytes memory creationCode = abi.encodePacked(
            type(FxHedgeHook).creationCode,
            abi.encode(IPoolManager(address(poolManager)), admin, threshold)
        );
        (address expected,) = HookMiner.find(address(this), _hedgeHookFlags(), creationCode, 500_000);
        deployCodeTo(_fxHedgeHookArtifact(), abi.encode(IPoolManager(address(poolManager)), admin, threshold), expected);
        deployedHook = FxHedgeHook(expected);
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
