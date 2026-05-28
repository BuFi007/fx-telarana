// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolRegistry} from "../src/hub/PoolRegistry.sol";
import {LiquidityRouter, IUniversalRouter, IV3SwapRouter, ILBRouter} from "../src/hub/LiquidityRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ── Venue mocks ────────────────────────────────────────────────────

/// @dev Mock Universal Router for v4. Pulls tokenIn from the LiquidityRouter
///      (which approved it) and mints tokenOut directly to `recipient`.
contract MockUniversalRouter is IUniversalRouter {
    MockERC20 public immutable TOKEN_OUT;
    uint256 public outAmount;

    constructor(MockERC20 tokenOut_, uint256 outAmount_) {
        TOKEN_OUT = tokenOut_;
        outAmount = outAmount_;
    }

    function setOutAmount(uint256 v) external {
        outAmount = v;
    }

    function execute(bytes calldata, /* commands */ bytes[] calldata inputs, uint256 /* deadline */ )
        external
        payable
        override
    {
        // Decode the placeholder input layout from LiquidityRouter._swapUniV4.
        (, address tokenIn, /* tokenOut */, uint256 amountIn,, address recipient) =
            abi.decode(inputs[0], (bytes32, address, address, uint256, uint256, address));

        // Pull tokenIn from the router caller (LiquidityRouter approved us).
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Mint tokenOut to recipient.
        TOKEN_OUT.mint(recipient, outAmount);
    }
}

/// @dev Mock V3 SwapRouter02. Honors `amountOutMinimum`.
contract MockV3SwapRouter is IV3SwapRouter {
    uint256 public outAmount;

    constructor(uint256 outAmount_) {
        outAmount = outAmount_;
    }

    function setOutAmount(uint256 v) external {
        outAmount = v;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable override returns (uint256) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        require(outAmount >= p.amountOutMinimum, "MockV3: slippage");
        MockERC20(p.tokenOut).mint(p.recipient, outAmount);
        return outAmount;
    }
}

/// @dev Mock Trader Joe LBRouter. Honors `amountOutMin`.
contract MockLBRouter is ILBRouter {
    uint256 public outAmount;

    constructor(uint256 outAmount_) {
        outAmount = outAmount_;
    }

    function setOutAmount(uint256 v) external {
        outAmount = v;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Path memory path,
        address to,
        uint256 /* deadline */
    ) external override returns (uint256) {
        IERC20(path.tokenPath[0]).transferFrom(msg.sender, address(this), amountIn);
        require(outAmount >= amountOutMin, "MockLB: slippage");
        MockERC20(path.tokenPath[path.tokenPath.length - 1]).mint(to, outAmount);
        return outAmount;
    }
}

// ── Test suite ─────────────────────────────────────────────────────

contract LiquidityRouterTest is Test {
    PoolRegistry internal registry;
    LiquidityRouter internal router;

    MockERC20 internal usdc;
    MockERC20 internal jpyc;

    address internal admin = address(0xA11CE);
    address internal trader = address(0x7AAD);
    address internal recipient = address(0xBABE);

    uint256 internal constant AMOUNT_IN = 100e6; // 100 USDC

    function setUp() public {
        registry = new PoolRegistry(admin);
        router = new LiquidityRouter(registry);

        usdc = new MockERC20("USDC", "USDC", 6);
        jpyc = new MockERC20("JPYC", "JPYC", 18);

        // Fund the trader and approve the router.
        usdc.mint(trader, 1_000_000e6);
        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);
    }

    function _addRoute(PoolRegistry.Venue venue, bool enabled) internal {
        PoolRegistry.Route memory r = PoolRegistry.Route({
            venue: venue,
            pool: address(0xC0DE),
            poolKey: bytes32(0),
            targetChainId: 0,
            spreadBps: 3000, // also encodes V3 fee tier
            enabled: enabled,
            preferred: true
        });
        vm.prank(admin);
        registry.addRoute(address(usdc), address(jpyc), r);
    }

    // ── Dispatch tests ──────────────────────────────────────────────

    function test_routesToConfiguredVenue_V3() public {
        uint256 expectedOut = 15_000e18;
        MockV3SwapRouter v3 = new MockV3SwapRouter(expectedOut);

        vm.prank(admin);
        registry.setVenueRouter(PoolRegistry.Venue.UniswapV3, address(v3));
        _addRoute(PoolRegistry.Venue.UniswapV3, true);

        vm.prank(trader);
        uint256 amountOut = router.swapExactIn(
            address(usdc), address(jpyc), AMOUNT_IN, expectedOut, recipient, block.timestamp + 1 hours
        );

        assertEq(amountOut, expectedOut);
        assertEq(jpyc.balanceOf(recipient), expectedOut);
        assertEq(usdc.balanceOf(address(v3)), AMOUNT_IN);
    }

    function test_dispatchToCorrectVenue_V4() public {
        uint256 expectedOut = 14_500e18;
        MockUniversalRouter v4 = new MockUniversalRouter(jpyc, expectedOut);

        vm.prank(admin);
        registry.setVenueRouter(PoolRegistry.Venue.UniswapV4, address(v4));
        _addRoute(PoolRegistry.Venue.UniswapV4, true);

        vm.prank(trader);
        uint256 amountOut = router.swapExactIn(
            address(usdc), address(jpyc), AMOUNT_IN, expectedOut, recipient, block.timestamp + 1 hours
        );

        assertEq(amountOut, expectedOut);
        assertEq(jpyc.balanceOf(recipient), expectedOut);
        assertEq(usdc.balanceOf(address(v4)), AMOUNT_IN);
    }

    function test_dispatchToCorrectVenue_SelfLPV4() public {
        uint256 expectedOut = 14_900e18;
        MockUniversalRouter v4 = new MockUniversalRouter(jpyc, expectedOut);

        // SelfLP_V4 and UniswapV4 share the same dispatch path; the spec uses
        // the SelfLP_V4 venueRouter slot for the testnet bootstrap.
        vm.prank(admin);
        registry.setVenueRouter(PoolRegistry.Venue.SelfLP_V4, address(v4));
        _addRoute(PoolRegistry.Venue.SelfLP_V4, true);

        vm.prank(trader);
        uint256 amountOut = router.swapExactIn(
            address(usdc), address(jpyc), AMOUNT_IN, expectedOut, recipient, block.timestamp + 1 hours
        );

        assertEq(amountOut, expectedOut);
    }

    function test_dispatchToCorrectVenue_TraderJoe() public {
        uint256 expectedOut = 14_800e18;
        MockLBRouter tj = new MockLBRouter(expectedOut);

        vm.prank(admin);
        registry.setVenueRouter(PoolRegistry.Venue.TraderJoeV22, address(tj));
        _addRoute(PoolRegistry.Venue.TraderJoeV22, true);

        vm.prank(trader);
        uint256 amountOut = router.swapExactIn(
            address(usdc), address(jpyc), AMOUNT_IN, expectedOut, recipient, block.timestamp + 1 hours
        );

        assertEq(amountOut, expectedOut);
        assertEq(jpyc.balanceOf(recipient), expectedOut);
        assertEq(usdc.balanceOf(address(tj)), AMOUNT_IN);
    }

    function test_revertsOnInsufficientOutput() public {
        // V3 mock returns less than minAmountOut → its own require trips.
        uint256 mockOut = 10e18;
        uint256 minOut = 20e18;
        MockV3SwapRouter v3 = new MockV3SwapRouter(mockOut);

        vm.prank(admin);
        registry.setVenueRouter(PoolRegistry.Venue.UniswapV3, address(v3));
        _addRoute(PoolRegistry.Venue.UniswapV3, true);

        vm.prank(trader);
        vm.expectRevert(bytes("MockV3: slippage"));
        router.swapExactIn(address(usdc), address(jpyc), AMOUNT_IN, minOut, recipient, block.timestamp + 1 hours);
    }

    function test_crossChainReverts() public {
        _addRoute(PoolRegistry.Venue.CrossChain, true);

        vm.prank(trader);
        vm.expectRevert(LiquidityRouter.CrossChainNotWired.selector);
        router.swapExactIn(address(usdc), address(jpyc), AMOUNT_IN, 0, recipient, block.timestamp + 1 hours);
    }

    function test_revertsWhenVenueRouterNotSet() public {
        _addRoute(PoolRegistry.Venue.UniswapV3, true);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityRouter.VenueRouterNotSet.selector, PoolRegistry.Venue.UniswapV3)
        );
        router.swapExactIn(address(usdc), address(jpyc), AMOUNT_IN, 0, recipient, block.timestamp + 1 hours);
    }

    function test_revertsOnDisabledRoute() public {
        // Add a disabled preferred route — `bestRoute` will revert PairNotFound
        // before reaching LiquidityRouter's enabled check, but either revert
        // counts as a refusal to dispatch.
        _addRoute(PoolRegistry.Venue.UniswapV3, false);

        vm.prank(trader);
        vm.expectRevert();
        router.swapExactIn(address(usdc), address(jpyc), AMOUNT_IN, 0, recipient, block.timestamp + 1 hours);
    }

    function test_revertsOnZeroAmount() public {
        _addRoute(PoolRegistry.Venue.UniswapV3, true);

        vm.prank(trader);
        vm.expectRevert(LiquidityRouter.ZeroAmount.selector);
        router.swapExactIn(address(usdc), address(jpyc), 0, 0, recipient, block.timestamp + 1 hours);
    }

    function test_revertsOnZeroRecipient() public {
        _addRoute(PoolRegistry.Venue.UniswapV3, true);

        vm.prank(trader);
        vm.expectRevert(LiquidityRouter.ZeroRecipient.selector);
        router.swapExactIn(address(usdc), address(jpyc), AMOUNT_IN, 0, address(0), block.timestamp + 1 hours);
    }

    function test_revertsOnDeadlinePassed() public {
        _addRoute(PoolRegistry.Venue.UniswapV3, true);

        vm.warp(1000);
        vm.prank(trader);
        vm.expectRevert(LiquidityRouter.DeadlinePassed.selector);
        router.swapExactIn(address(usdc), address(jpyc), AMOUNT_IN, 0, recipient, 999);
    }

    function test_quoteReturnsVenueAndZeroAmount() public {
        _addRoute(PoolRegistry.Venue.UniswapV3, true);
        (uint256 amountOut, PoolRegistry.Venue venue) = router.quote(address(usdc), address(jpyc), AMOUNT_IN);
        assertEq(amountOut, 0, "quote is a stub today");
        assertEq(uint256(venue), uint256(PoolRegistry.Venue.UniswapV3));
    }
}
