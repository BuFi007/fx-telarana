// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {FxSpotExecutor} from "../src/spot/FxSpotExecutor.sol";
import {IFxOracle} from "../src/interfaces/IFxOracle.sol";
import {ITelaranaGatewayHubHook} from "../src/interfaces/ITelaranaGatewayHubHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Stub FxOracle that returns a configurable mid. Mid is in
///         "tokenOut per USDC" * 1e18 — what `getMid(USDC, tokenOut)` returns.
contract MockFxOracle is IFxOracle {
    mapping(bytes32 => uint256) public midE18;
    mapping(bytes32 => uint256) public publishedAt;

    function setMid(address base, address quote, uint256 mid) external {
        midE18[keccak256(abi.encode(base, quote))] = mid;
        publishedAt[keccak256(abi.encode(base, quote))] = block.timestamp;
    }

    function getMid(address base, address quote) external view returns (uint256, uint256) {
        bytes32 k = keccak256(abi.encode(base, quote));
        uint256 mid = midE18[k];
        if (mid == 0) revert OracleFeedUnknown(base, quote);
        return (mid, publishedAt[k]);
    }

    function getMidVerified(address base, address quote) external view returns (uint256, uint256) {
        return this.getMid(base, quote);
    }

    function getMidWithUpdate(address, address, bytes[] calldata) external payable returns (uint256, uint256) {
        revert("not impl");
    }

    function getMidWithUpdatePyth(address, address, bytes[] calldata) external payable returns (uint256, uint256) {
        revert("not impl");
    }

    function priceOf(address) external pure returns (uint256, uint256) {
        revert("not impl");
    }

    function config() external pure returns (uint256, uint256, uint256) {
        return (60, 50, 30);
    }
}

/// @notice Stub TGH that exposes `gatewayReceipt(requestId)` and accepts
///         `markGatewayAtomicFxSwapSettled` from any caller.
contract MockTelaranaGatewayHubHook is ITelaranaGatewayHubHook {
    mapping(bytes32 => GatewayReceipt) internal _receipts;
    mapping(bytes32 => bool) public settled;

    function setReceipt(bytes32 requestId, GatewayReceipt memory r) external {
        _receipts[requestId] = r;
    }

    function gatewayReceipt(bytes32 requestId) external view returns (GatewayReceipt memory) {
        return _receipts[requestId];
    }

    function markGatewayAtomicFxSwapSettled(bytes32 requestId, uint256 /*amountOut*/) external {
        GatewayReceipt storage r = _receipts[requestId];
        require(r.state == GatewayRequestState.MINTED, "not minted");
        require(r.action == GatewayHubAction.MINT_AND_REQUEST_SPOT_FX, "not spot fx");
        r.state = GatewayRequestState.SETTLED;
        settled[requestId] = true;
    }

    // Unused interface members.
    function gatewayRoute(bytes32) external pure returns (GatewayHubRoute memory r) { return r; }
    function gatewayRequestState(bytes32 requestId) external view returns (GatewayRequestState) {
        return _receipts[requestId].state;
    }
    function setGatewayRoute(bytes32, GatewayHubRoute calldata) external pure { revert("unused"); }
    function setGatewaySignerMode(bytes32, GatewaySignerMode, bool) external pure { revert("unused"); }
    function receiveGatewayMint(bytes calldata, bytes calldata, GatewayMintContext calldata)
        external pure returns (uint256) { revert("unused"); }
}

contract FxSpotExecutorTest is Test {
    FxSpotExecutor public executor;
    MockFxOracle public oracle;
    MockTelaranaGatewayHubHook public tgh;
    MockERC20 public usdc;
    MockERC20 public eurc;

    address internal constant ADMIN = address(uint160(uint256(keccak256("spot.test.ADMIN"))));
    address internal constant KEEPER = address(uint160(uint256(keccak256("spot.test.KEEPER"))));
    address internal constant TRADER = address(uint160(uint256(keccak256("spot.test.TRADER"))));
    address internal constant OUTSIDER = address(uint160(uint256(keccak256("spot.test.OUTSIDER"))));

    bytes32 internal constant ROUTE_ID = keccak256("spot.test.route.fuji-to-arc.usdc-eurc.spot-fx");
    bytes32 internal constant REQUEST_ID = keccak256("spot.test.request-1");

    // 1.08 EUR per USD inverted: 1 USDC = 1 / 1.08 EUR ≈ 0.9259 EUR.
    // getMid(USDC, EURC) returns "EURC per USDC" * 1e18 = 0.9259e18.
    uint256 internal constant MID_USDC_TO_EURC_E18 = 925_925_925_925_925_926; // ≈ 0.9259e18

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        oracle = new MockFxOracle();
        tgh = new MockTelaranaGatewayHubHook();

        executor = new FxSpotExecutor(
            address(usdc),
            address(oracle),
            address(tgh),
            ADMIN,
            5 // 5 bps default spread
        );

        vm.startPrank(ADMIN);
        executor.setTokenEnabled(address(eurc), true);
        executor.grantRole(executor.EXECUTOR_ROLE(), KEEPER);
        executor.grantRole(executor.OPERATIONS_ROLE(), ADMIN);
        vm.stopPrank();

        oracle.setMid(address(usdc), address(eurc), MID_USDC_TO_EURC_E18);

        // Seed liquidity: 100 USDC + 100 EURC.
        eurc.mint(ADMIN, 100e6);
        vm.startPrank(ADMIN);
        eurc.approve(address(executor), 100e6);
        executor.addLiquidity(address(eurc), 100e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_executeSpotFx_happyPath() public {
        // Simulate TGH delivering 1 USDC to the executor.
        usdc.mint(address(executor), 1e6);

        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, 1e6, 900_000);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(ctx);

        // Expected: 1e6 * 0.9259e18 / 1e18 = 925_925, less 5 bps spread:
        // 925_925 * 9995 / 10000 = 925_462 (integer arithmetic).
        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * 9995 / 10_000;
        assertEq(amountOut, expected, "amountOut");
        assertEq(eurc.balanceOf(TRADER), expected, "trader received EURC");
        assertEq(usdc.balanceOf(address(executor)), 1e6, "USDC stays in executor pool");
        assertTrue(executor.executed(REQUEST_ID), "executed flag");
        assertTrue(tgh.settled(REQUEST_ID), "TGH settled");
    }

    function test_executeSpotFx_appliesPerTokenSpreadOverride() public {
        vm.prank(ADMIN);
        executor.setTokenSpreadBps(address(eurc), 25); // 25 bps override

        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));

        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * (10_000 - 25) / 10_000;
        assertEq(amountOut, expected);
    }

    /*//////////////////////////////////////////////////////////////
                                GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_executeSpotFx_revertsForOutsider() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                OUTSIDER,
                executor.EXECUTOR_ROLE()
            )
        );
        vm.prank(OUTSIDER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));
    }

    function test_executeSpotFx_revertsOnDuplicate() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000);

        vm.prank(KEEPER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.AlreadyExecuted.selector, REQUEST_ID));
        vm.prank(KEEPER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));
    }

    function test_executeSpotFx_revertsOnWrongAction() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, 1e6, 900_000);
        ctx.action = ITelaranaGatewayHubHook.GatewayHubAction.MINT_TO_HUB;

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.InvalidAction.selector, 0));
        vm.prank(KEEPER);
        executor.executeSpotFx(ctx);
    }

    function test_executeSpotFx_revertsOnTokenNotEnabled() public {
        MockERC20 jpyc = new MockERC20("JPYC", "JPYC", 6);
        usdc.mint(address(executor), 1e6);
        _setReceiptWithToken(REQUEST_ID, 1e6, address(jpyc), 100_000_000);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, 1e6, 100_000_000);
        ctx.tokenOut = address(jpyc);

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.TokenNotEnabled.selector, address(jpyc)));
        vm.prank(KEEPER);
        executor.executeSpotFx(ctx);
    }

    function test_executeSpotFx_revertsOnSlippage() public {
        usdc.mint(address(executor), 1e6);
        // minAmountOut higher than what the spread allows.
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 999_999);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, 1e6, 999_999);

        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * 9995 / 10_000;

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.SlippageExceeded.selector, expected, 999_999));
        vm.prank(KEEPER);
        executor.executeSpotFx(ctx);
    }

    function test_executeSpotFx_revertsOnInsufficientReserves() public {
        // Drain EURC reserves first.
        vm.prank(ADMIN);
        executor.withdrawLiquidity(address(eurc), 100e6, ADMIN);

        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 1);

        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * 9995 / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(FxSpotExecutor.InsufficientReserves.selector, address(eurc), expected, 0)
        );
        vm.prank(KEEPER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 1));
    }

    function test_executeSpotFx_revertsOnReceiptRouteMismatch() public {
        usdc.mint(address(executor), 1e6);
        bytes32 wrongRoute = keccak256("different.route");
        ITelaranaGatewayHubHook.GatewayReceipt memory r = ITelaranaGatewayHubHook.GatewayReceipt({
            routeId: wrongRoute,
            state: ITelaranaGatewayHubHook.GatewayRequestState.MINTED,
            action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX,
            sourceDepositor: TRADER,
            sourceSigner: TRADER,
            recipient: TRADER,
            tokenOut: address(eurc),
            amount: 1e6,
            minAmountOut: 900_000,
            spotRouteId: bytes32(0),
            metadataRef: bytes32(0)
        });
        tgh.setReceipt(REQUEST_ID, r);

        vm.expectRevert(
            abi.encodeWithSelector(FxSpotExecutor.RouteIdMismatch.selector, wrongRoute, ROUTE_ID)
        );
        vm.prank(KEEPER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));
    }

    function test_executeSpotFx_revertsOnReceiptAmountMismatch() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 2e6, address(eurc), 900_000); // receipt says 2 USDC

        vm.expectRevert(
            abi.encodeWithSelector(FxSpotExecutor.AmountMismatch.selector, 2e6, 1e6)
        );
        vm.prank(KEEPER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));
    }

    function test_executeSpotFx_revertsWhenPaused() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000);

        vm.prank(ADMIN);
        executor.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(KEEPER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));
    }

    function test_executeSpotFx_revertsOnUsdcAsTokenOut() public {
        usdc.mint(address(executor), 1e6);
        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, 1e6, 900_000);
        ctx.tokenOut = address(usdc);

        vm.expectRevert(FxSpotExecutor.UsdcAsTokenOut.selector);
        vm.prank(KEEPER);
        executor.executeSpotFx(ctx);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setTokenEnabled_revertsForUsdc() public {
        vm.expectRevert(FxSpotExecutor.UsdcAsTokenOut.selector);
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(usdc), true);
    }

    function test_setDefaultSpreadBps_revertsAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.InvalidSpread.selector, 501));
        vm.prank(ADMIN);
        executor.setDefaultSpreadBps(501);
    }

    function test_addLiquidity_happyPath() public {
        eurc.mint(ADMIN, 50e6);
        vm.startPrank(ADMIN);
        eurc.approve(address(executor), 50e6);
        executor.addLiquidity(address(eurc), 50e6);
        vm.stopPrank();
        assertEq(executor.reserveOf(address(eurc)), 150e6, "reserve grew");
    }

    function test_withdrawLiquidity_happyPath() public {
        vm.prank(ADMIN);
        executor.withdrawLiquidity(address(eurc), 10e6, OUTSIDER);
        assertEq(eurc.balanceOf(OUTSIDER), 10e6);
    }

    function test_executor_canBeRotated() public {
        address newKeeper = address(uint160(uint256(keccak256("spot.test.NEW_KEEPER"))));
        vm.startPrank(ADMIN);
        executor.revokeRole(executor.EXECUTOR_ROLE(), KEEPER);
        executor.grantRole(executor.EXECUTOR_ROLE(), newKeeper);
        vm.stopPrank();

        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000);

        vm.expectRevert();
        vm.prank(KEEPER);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));

        vm.prank(newKeeper);
        executor.executeSpotFx(_ctx(REQUEST_ID, 1e6, 900_000));
        assertTrue(executor.executed(REQUEST_ID));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setReceipt(bytes32 requestId, uint256 amount, address tokenOut, uint256 minAmountOut) internal {
        _setReceiptWithToken(requestId, amount, tokenOut, minAmountOut);
    }

    function _setReceiptWithToken(bytes32 requestId, uint256 amount, address tokenOut, uint256 minAmountOut)
        internal
    {
        ITelaranaGatewayHubHook.GatewayReceipt memory r = ITelaranaGatewayHubHook.GatewayReceipt({
            routeId: ROUTE_ID,
            state: ITelaranaGatewayHubHook.GatewayRequestState.MINTED,
            action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX,
            sourceDepositor: TRADER,
            sourceSigner: TRADER,
            recipient: TRADER,
            tokenOut: tokenOut,
            amount: amount,
            minAmountOut: minAmountOut,
            spotRouteId: bytes32(0),
            metadataRef: bytes32(0)
        });
        tgh.setReceipt(requestId, r);
    }

    function _ctx(bytes32 requestId, uint256 amount, uint256 minAmountOut)
        internal
        view
        returns (ITelaranaGatewayHubHook.GatewayMintContext memory)
    {
        return ITelaranaGatewayHubHook.GatewayMintContext({
            routeId: ROUTE_ID,
            requestId: requestId,
            action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX,
            sourceDepositor: TRADER,
            sourceSigner: TRADER,
            recipient: TRADER,
            tokenOut: address(eurc),
            amount: amount,
            minAmountOut: minAmountOut,
            spotRouteId: bytes32(0),
            metadataRef: bytes32(0),
            hookData: ""
        });
    }
}
