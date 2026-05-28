// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolRegistry} from "./PoolRegistry.sol";

/// @dev Minimal local interface for Uniswap v4's Universal Router. We avoid a
///      new package dependency — only `execute` is used by the dispatcher.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Minimal local interface for Uniswap V3 SwapRouter02 `exactInputSingle`.
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @dev Minimal local interface for Trader Joe v2.2 LBRouter.
interface ILBRouter {
    struct Path {
        uint256[] pairBinSteps;
        uint8[] versions;
        address[] tokenPath;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Path memory path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

/// @title LiquidityRouter
/// @notice Thin adapter that dispatches `swap()` calls to the venue-specific
///         routers (Uniswap V4 Universal Router, V3 SwapRouter02, Trader Joe
///         LBRouter) based on the active `PoolRegistry` route. FxSpotExecutor
///         calls this instead of holding inventory.
contract LiquidityRouter {
    using SafeERC20 for IERC20;

    PoolRegistry public immutable REGISTRY;

    /// @notice Default pool fee tier used when a V3 route does not encode one.
    ///         0.3% is the canonical FX-ish pool default. Routes can override
    ///         by encoding the fee into `Route.spreadBps`.
    uint24 internal constant DEFAULT_V3_FEE = 3000;

    error UnsupportedVenue(PoolRegistry.Venue venue);
    error RouteDisabled();
    error InsufficientOutput(uint256 received, uint256 minOut);
    error VenueRouterNotSet(PoolRegistry.Venue venue);
    error ZeroAmount();
    error ZeroRecipient();
    error DeadlinePassed();
    error CrossChainNotWired();

    event SwapExecuted(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        PoolRegistry.Venue venue,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    constructor(PoolRegistry registry) {
        if (address(registry) == address(0)) revert ZeroRecipient();
        REGISTRY = registry;
    }

    /// @notice Swap exact `amountIn` of `tokenIn` for at least `minAmountOut`
    ///         of `tokenOut`, dispatching to the registry's best route.
    /// @dev    Caller must approve this contract for `amountIn` beforehand.
    ///         The post-dispatch slippage check is belt-and-suspenders — venue
    ///         routers also enforce `minAmountOut`, but we re-check in case a
    ///         downstream dispatcher returns a different value.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroRecipient();
        if (deadline < block.timestamp) revert DeadlinePassed();

        PoolRegistry.Route memory route = REGISTRY.bestRoute(tokenIn, tokenOut);
        if (!route.enabled) revert RouteDisabled();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (route.venue == PoolRegistry.Venue.UniswapV4 || route.venue == PoolRegistry.Venue.SelfLP_V4) {
            amountOut = _swapUniV4(tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline, route);
        } else if (route.venue == PoolRegistry.Venue.UniswapV3) {
            amountOut = _swapUniV3(tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline, route);
        } else if (route.venue == PoolRegistry.Venue.TraderJoeV22) {
            amountOut = _swapTraderJoe(tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline, route);
        } else if (route.venue == PoolRegistry.Venue.CrossChain) {
            amountOut = _swapCrossChain(tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline, route);
        } else {
            revert UnsupportedVenue(route.venue);
        }

        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, route.venue, amountIn, amountOut, recipient);
    }

    /// @notice Quote without executing. Stub for the UI / FxHedgeHook fallback.
    /// @dev    Returns 0 today — venue-specific quoters (UniswapV4Quoter,
    ///         UniswapV3Quoter, TraderJoeQuoter) will be wired in a follow-up.
    ///         Callers should fall back to an oracle price (Pyth/RedStone).
    function quote(address tokenIn, address tokenOut, uint256 /* amountIn */ )
        external
        view
        returns (uint256 amountOut, PoolRegistry.Venue venue)
    {
        PoolRegistry.Route memory route = REGISTRY.bestRoute(tokenIn, tokenOut);
        venue = route.venue;
        amountOut = 0; // stub — fall back to oracle price client-side.
    }

    // ── Venue dispatch ──────────────────────────────────────────────

    /// @dev Uniswap v4 dispatch via the Universal Router. The router consumes
    ///      ABI-encoded commands + inputs prepared by the caller (off-chain
    ///      planner). For now we approve the router, forward the encoded call,
    ///      and measure delta from the recipient's tokenOut balance.
    function _swapUniV4(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline,
        PoolRegistry.Route memory route
    ) internal returns (uint256 amountOut) {
        address router = REGISTRY.venueRouters(route.venue);
        if (router == address(0)) revert VenueRouterNotSet(route.venue);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(recipient);

        IERC20(tokenIn).forceApprove(router, amountIn);

        // The Universal Router consumes pre-encoded V4_SWAP commands. We forward
        // a single-action plan that swaps `amountIn` of tokenIn into tokenOut
        // with the route's poolKey, routing the output to `recipient`. The
        // exact command/input layout is finalized in the integration task.
        bytes memory commands = abi.encodePacked(bytes1(uint8(0x00))); // V4_SWAP placeholder
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(route.poolKey, tokenIn, tokenOut, amountIn, minAmountOut, recipient);

        IUniversalRouter(router).execute(commands, inputs, deadline);

        amountOut = IERC20(tokenOut).balanceOf(recipient) - balanceBefore;
    }

    /// @dev Uniswap V3 dispatch via SwapRouter02.exactInputSingle.
    function _swapUniV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256, /* deadline — SwapRouter02 dropped the param */
        PoolRegistry.Route memory route
    ) internal returns (uint256 amountOut) {
        address router = REGISTRY.venueRouters(route.venue);
        if (router == address(0)) revert VenueRouterNotSet(route.venue);

        IERC20(tokenIn).forceApprove(router, amountIn);

        // spreadBps doubles as a V3 fee-tier hint when nonzero (e.g. 500/3000/10000).
        uint24 fee = route.spreadBps == 0 ? DEFAULT_V3_FEE : uint24(route.spreadBps);

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = IV3SwapRouter(router).exactInputSingle(params);
    }

    /// @dev Trader Joe v2.2 dispatch via LBRouter.swapExactTokensForTokens.
    function _swapTraderJoe(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline,
        PoolRegistry.Route memory route
    ) internal returns (uint256 amountOut) {
        address router = REGISTRY.venueRouters(route.venue);
        if (router == address(0)) revert VenueRouterNotSet(route.venue);

        IERC20(tokenIn).forceApprove(router, amountIn);

        ILBRouter.Path memory path;
        path.pairBinSteps = new uint256[](1);
        path.pairBinSteps[0] = 0; // bin step encoded in pool config; router resolves
        path.versions = new uint8[](1);
        path.versions[0] = 2; // V2_2
        path.tokenPath = new address[](2);
        path.tokenPath[0] = tokenIn;
        path.tokenPath[1] = tokenOut;

        amountOut = ILBRouter(router).swapExactTokensForTokens(amountIn, minAmountOut, path, recipient, deadline);
    }

    /// @notice Cross-chain swap via Telarana gateway + CCTP.
    /// @dev    Burns tokenIn on this chain, mints on targetChain, executes the
    ///         swap there, and bridges tokenOut back. Slow (~2 min) but taps
    ///         real mainnet liquidity. Reverts until the gateway integration
    ///         lands in a follow-up task.
    function _swapCrossChain(
        address, /* tokenIn */
        address, /* tokenOut */
        uint256, /* amountIn */
        uint256, /* minAmountOut */
        address, /* recipient */
        uint256, /* deadline */
        PoolRegistry.Route memory /* route */
    ) internal pure returns (uint256) {
        revert CrossChainNotWired();
    }
}
