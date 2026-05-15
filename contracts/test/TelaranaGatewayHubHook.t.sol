// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ICircleGatewayMinter} from "../src/interfaces/ICircleGateway.sol";
import {ITelaranaGatewayHubHook} from "../src/interfaces/ITelaranaGatewayHubHook.sol";
import {TelaranaGatewayHubHook} from "../src/hub/TelaranaGatewayHubHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockCircleGatewayMinter is ICircleGatewayMinter {
    MockERC20 public immutable usdc;
    address public mintRecipient;
    uint256 public mintAmount;
    bytes32 public lastPayloadHash;
    bytes32 public lastSignatureHash;

    constructor(address usdc_) {
        usdc = MockERC20(usdc_);
    }

    function setMint(address recipient, uint256 amount) external {
        mintRecipient = recipient;
        mintAmount = amount;
    }

    function gatewayMint(bytes calldata attestationPayload, bytes calldata signature) external {
        lastPayloadHash = keccak256(attestationPayload);
        lastSignatureHash = keccak256(signature);
        usdc.mint(mintRecipient, mintAmount);
    }
}

contract TelaranaGatewayHubHookTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal jpyc;
    MockCircleGatewayMinter internal minter;
    TelaranaGatewayHubHook internal hook;

    address internal admin = address(this);
    address internal executor = address(0xE0E);
    address internal destinationHub = address(0xA11CE);
    address internal sourceUsdc = address(0xF1F1);
    address internal sourceGatewayWallet = address(0x7777);
    address internal sourceDepositor = address(0xD3F0517);
    address internal sourceSigner = address(0x519E7);
    address internal recipient = address(0xB0B);

    bytes32 internal constant ROUTE_ID = keccak256("gateway-fuji-to-arc-usdc");
    bytes32 internal constant REQUEST_ID = keccak256("request-1");
    bytes32 internal constant SPOT_ROUTE_ID = keccak256("arc-usdc-jpyc-spot");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        jpyc = new MockERC20("JPYC", "JPYC", 18);
        minter = new MockCircleGatewayMinter(address(usdc));
        hook = new TelaranaGatewayHubHook(address(usdc), address(minter), admin);

        hook.grantRole(hook.EXECUTOR_ROLE(), executor);
        hook.setGatewayRoute(ROUTE_ID, _route(true, executor));
    }

    function test_receiveGatewayMint_forwardsUsdcToDestinationHub() public {
        minter.setMint(address(hook), 100e6);

        vm.prank(executor);
        uint256 amountReceived = hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));

        assertEq(amountReceived, 100e6);
        assertEq(usdc.balanceOf(address(hook)), 0);
        assertEq(usdc.balanceOf(destinationHub), 100e6);
        assertEq(uint8(hook.gatewayRequestState(REQUEST_ID)), uint8(ITelaranaGatewayHubHook.GatewayRequestState.MINTED));

        ITelaranaGatewayHubHook.GatewayReceipt memory receipt = hook.gatewayReceipt(REQUEST_ID);
        assertEq(receipt.routeId, ROUTE_ID);
        assertEq(receipt.amount, 100e6);
        assertEq(receipt.recipient, recipient);
        assertEq(receipt.sourceDepositor, sourceDepositor);
        assertEq(receipt.sourceSigner, sourceSigner);
    }

    function test_receiveGatewayMint_revertsForNonExecutor() public {
        minter.setMint(address(hook), 100e6);

        vm.expectRevert();
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));
    }

    function test_receiveGatewayMint_revertsForWrongRouteCaller() public {
        address otherExecutor = address(0xE0F);
        hook.grantRole(hook.EXECUTOR_ROLE(), otherExecutor);
        minter.setMint(address(hook), 100e6);

        vm.prank(otherExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(TelaranaGatewayHubHook.UnauthorizedRouteCaller.selector, ROUTE_ID, otherExecutor)
        );
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));
    }

    function test_receiveGatewayMint_revertsOnAmountMismatch() public {
        minter.setMint(address(hook), 99e6);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.InvalidMintAmount.selector, 100e6, 99e6));
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));
    }

    function test_receiveGatewayMint_revertsOnDuplicateRequest() public {
        minter.setMint(address(hook), 100e6);

        vm.prank(executor);
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));

        minter.setMint(address(hook), 100e6);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.DuplicateRequest.selector, REQUEST_ID));
        hook.receiveGatewayMint("attestation-2", "signature-2", _context(REQUEST_ID, 100e6));
    }

    function test_receiveGatewayMint_revertsWhenRouteDisabled() public {
        hook.setGatewayRoute(ROUTE_ID, _route(false, executor));
        minter.setMint(address(hook), 100e6);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.RouteDisabled.selector, ROUTE_ID));
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));
    }

    function test_receiveGatewayMint_revertsWhenPaused() public {
        hook.pause();
        minter.setMint(address(hook), 100e6);

        vm.prank(executor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));
    }

    function test_receiveGatewayMint_revertsOnUnexpectedHookData() public {
        minter.setMint(address(hook), 100e6);
        ITelaranaGatewayHubHook.GatewayMintContext memory context = _context(REQUEST_ID, 100e6);
        context.hookData = "future-hook-data";

        vm.prank(executor);
        vm.expectRevert(TelaranaGatewayHubHook.UnexpectedHookData.selector);
        hook.receiveGatewayMint("attestation", "signature", context);
    }

    function test_receiveGatewayMint_revertsOnMintToHubWithSpotFields() public {
        minter.setMint(address(hook), 100e6);
        ITelaranaGatewayHubHook.GatewayMintContext memory context = _context(REQUEST_ID, 100e6);
        context.tokenOut = address(jpyc);
        context.minAmountOut = 1_000e18;
        context.spotRouteId = SPOT_ROUTE_ID;

        vm.prank(executor);
        vm.expectRevert(TelaranaGatewayHubHook.InvalidSpotRequest.selector);
        hook.receiveGatewayMint("attestation", "signature", context);
    }

    function test_receiveGatewayMint_canKeepFundsWhenDestinationHubIsHook() public {
        hook.setGatewayRoute(ROUTE_ID, _routeWithDestination(address(hook)));
        minter.setMint(address(hook), 100e6);

        vm.prank(executor);
        uint256 amountReceived = hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));

        assertEq(amountReceived, 100e6);
        assertEq(usdc.balanceOf(address(hook)), 100e6);
        assertEq(usdc.balanceOf(destinationHub), 0);
    }

    function test_receiveGatewayMint_recordsSpotRequestAndSettlement() public {
        bytes32 requestId = keccak256("spot-request");
        minter.setMint(address(hook), 250e6);

        ITelaranaGatewayHubHook.GatewayMintContext memory context = _context(requestId, 250e6);
        context.action = ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX;
        context.tokenOut = address(jpyc);
        context.minAmountOut = 1_000e18;
        context.spotRouteId = SPOT_ROUTE_ID;

        vm.prank(executor);
        uint256 amountReceived = hook.receiveGatewayMint("attestation", "signature", context);

        assertEq(amountReceived, 250e6);
        assertEq(usdc.balanceOf(destinationHub), 250e6);

        ITelaranaGatewayHubHook.GatewayReceipt memory receipt = hook.gatewayReceipt(requestId);
        assertEq(uint8(receipt.action), uint8(ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX));
        assertEq(receipt.tokenOut, address(jpyc));
        assertEq(receipt.minAmountOut, 1_000e18);
        assertEq(receipt.spotRouteId, SPOT_ROUTE_ID);

        vm.prank(executor);
        hook.markGatewayAtomicFxSwapSettled(requestId, 1_050e18);

        assertEq(uint8(hook.gatewayRequestState(requestId)), uint8(ITelaranaGatewayHubHook.GatewayRequestState.SETTLED));
    }

    function test_markGatewayAtomicFxSwapSettled_revertsForMintOnlyRequest() public {
        minter.setMint(address(hook), 100e6);

        vm.prank(executor);
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));

        vm.prank(executor);
        vm.expectRevert(TelaranaGatewayHubHook.InvalidSpotRequest.selector);
        hook.markGatewayAtomicFxSwapSettled(REQUEST_ID, 1_000e18);
    }

    function test_markGatewayAtomicFxSwapSettled_revertsForNonExecutor() public {
        bytes32 requestId = keccak256("spot-request");
        minter.setMint(address(hook), 250e6);

        ITelaranaGatewayHubHook.GatewayMintContext memory context = _context(requestId, 250e6);
        context.action = ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX;
        context.tokenOut = address(jpyc);
        context.minAmountOut = 1_000e18;
        context.spotRouteId = SPOT_ROUTE_ID;

        vm.prank(executor);
        hook.receiveGatewayMint("attestation", "signature", context);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.markGatewayAtomicFxSwapSettled(requestId, 1_050e18);
    }

    function test_markGatewayAtomicFxSwapSettled_revertsBelowMinAmountOut() public {
        bytes32 requestId = keccak256("spot-underfill");
        minter.setMint(address(hook), 250e6);

        ITelaranaGatewayHubHook.GatewayMintContext memory context = _context(requestId, 250e6);
        context.action = ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX;
        context.tokenOut = address(jpyc);
        context.minAmountOut = 1_000e18;
        context.spotRouteId = SPOT_ROUTE_ID;

        vm.prank(executor);
        hook.receiveGatewayMint("attestation", "signature", context);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(TelaranaGatewayHubHook.InsufficientGatewayAmountOut.selector, 1_000e18, 999e18)
        );
        hook.markGatewayAtomicFxSwapSettled(requestId, 999e18);

        assertEq(uint8(hook.gatewayRequestState(requestId)), uint8(ITelaranaGatewayHubHook.GatewayRequestState.MINTED));
    }

    function test_setGatewaySignerMode_canDisableRouteMode() public {
        hook.setGatewaySignerMode(ROUTE_ID, ITelaranaGatewayHubHook.GatewaySignerMode.EOA, false);
        minter.setMint(address(hook), 100e6);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.RouteDisabled.selector, ROUTE_ID));
        hook.receiveGatewayMint("attestation", "signature", _context(REQUEST_ID, 100e6));
    }

    function test_setGatewayRoute_revertsSameDomain() public {
        ITelaranaGatewayHubHook.GatewayHubRoute memory route = _route(true, executor);
        route.destinationDomain = route.sourceDomain;

        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.SameGatewayDomain.selector, route.sourceDomain));
        hook.setGatewayRoute(keccak256("same-domain-route"), route);
    }

    function test_setGatewayRoute_revertsWrongMinter() public {
        ITelaranaGatewayHubHook.GatewayHubRoute memory route = _route(true, executor);
        route.destinationGatewayMinter = address(0xBAD);

        vm.expectRevert(
            abi.encodeWithSelector(TelaranaGatewayHubHook.RouteMinterMismatch.selector, address(minter), address(0xBAD))
        );
        hook.setGatewayRoute(keccak256("wrong-minter-route"), route);
    }

    function test_setGatewayRoute_revertsWrongDestinationUsdc() public {
        ITelaranaGatewayHubHook.GatewayHubRoute memory route = _route(true, executor);
        route.destinationUsdc = address(jpyc);

        vm.expectRevert(
            abi.encodeWithSelector(TelaranaGatewayHubHook.RouteTokenMismatch.selector, address(usdc), address(jpyc))
        );
        hook.setGatewayRoute(keccak256("wrong-usdc-route"), route);
    }

    function _route(bool enabled, address whitelistedCaller)
        internal
        view
        returns (ITelaranaGatewayHubHook.GatewayHubRoute memory)
    {
        return ITelaranaGatewayHubHook.GatewayHubRoute({
            sourceDomain: 1,
            destinationDomain: 26,
            sourceUsdc: sourceUsdc,
            destinationUsdc: address(usdc),
            sourceGatewayWallet: sourceGatewayWallet,
            destinationGatewayMinter: address(minter),
            destinationHub: destinationHub,
            whitelistedCaller: whitelistedCaller,
            signerMode: ITelaranaGatewayHubHook.GatewaySignerMode.EOA,
            enabled: enabled,
            metadataRef: keccak256("telarana-gateway-fuji-arc-v0")
        });
    }

    function _routeWithDestination(address routeDestinationHub)
        internal
        view
        returns (ITelaranaGatewayHubHook.GatewayHubRoute memory route)
    {
        route = _route(true, executor);
        route.destinationHub = routeDestinationHub;
    }

    function _context(bytes32 requestId, uint256 amount)
        internal
        view
        returns (ITelaranaGatewayHubHook.GatewayMintContext memory)
    {
        return ITelaranaGatewayHubHook.GatewayMintContext({
            routeId: ROUTE_ID,
            requestId: requestId,
            action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_TO_HUB,
            sourceDepositor: sourceDepositor,
            sourceSigner: sourceSigner,
            recipient: recipient,
            tokenOut: address(0),
            amount: amount,
            minAmountOut: 0,
            spotRouteId: bytes32(0),
            metadataRef: keccak256("request-metadata"),
            hookData: ""
        });
    }
}
