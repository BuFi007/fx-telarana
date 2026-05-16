// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {FxSpotExecutor} from "../src/spot/FxSpotExecutor.sol";
import {IFxOracle} from "../src/interfaces/IFxOracle.sol";
import {ITelaranaGatewayHubHook} from "../src/interfaces/ITelaranaGatewayHubHook.sol";
import {TestnetFiatToken} from "../src/testnet/TestnetFiatToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Stub FxOracle that returns a configurable mid in 1e18 fixed-point.
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
    uint256 internal constant MID_USDC_TO_EURC_E18 = 925_925_925_925_925_926;

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

        // Seed liquidity: 100 EURC.
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
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000, TRADER);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(REQUEST_ID);

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
        executor.setTokenSpreadBps(address(eurc), 25);

        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000, TRADER);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(REQUEST_ID);

        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * (10_000 - 25) / 10_000;
        assertEq(amountOut, expected);
    }

    /*//////////////////////////////////////////////////////////////
                                GUARDS — original 17
    //////////////////////////////////////////////////////////////*/

    function test_executeSpotFx_revertsForOutsider() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000, TRADER);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                OUTSIDER,
                executor.EXECUTOR_ROLE()
            )
        );
        vm.prank(OUTSIDER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnDuplicate() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000, TRADER);

        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.AlreadyExecuted.selector, REQUEST_ID));
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnEmptyReceipt() public {
        // No setReceipt — receipt.amount == 0
        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.EmptyReceipt.selector, REQUEST_ID));
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnReceiptNotMinted() public {
        // Receipt with state = UNKNOWN (state machine pre-mint)
        ITelaranaGatewayHubHook.GatewayReceipt memory r = _baseReceipt(1e6, address(eurc), 900_000, TRADER);
        r.state = ITelaranaGatewayHubHook.GatewayRequestState.UNKNOWN;
        tgh.setReceipt(REQUEST_ID, r);

        vm.expectRevert(
            abi.encodeWithSelector(
                FxSpotExecutor.ReceiptNotMinted.selector,
                REQUEST_ID,
                uint8(ITelaranaGatewayHubHook.GatewayRequestState.UNKNOWN)
            )
        );
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnReceiptAlreadySettled() public {
        ITelaranaGatewayHubHook.GatewayReceipt memory r = _baseReceipt(1e6, address(eurc), 900_000, TRADER);
        r.state = ITelaranaGatewayHubHook.GatewayRequestState.SETTLED;
        tgh.setReceipt(REQUEST_ID, r);

        vm.expectRevert(
            abi.encodeWithSelector(
                FxSpotExecutor.ReceiptNotMinted.selector,
                REQUEST_ID,
                uint8(ITelaranaGatewayHubHook.GatewayRequestState.SETTLED)
            )
        );
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnWrongAction() public {
        ITelaranaGatewayHubHook.GatewayReceipt memory r = _baseReceipt(1e6, address(eurc), 900_000, TRADER);
        r.action = ITelaranaGatewayHubHook.GatewayHubAction.MINT_TO_HUB;
        tgh.setReceipt(REQUEST_ID, r);

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.InvalidAction.selector, 0));
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnTokenNotEnabled() public {
        TestnetFiatToken jpyc = new TestnetFiatToken("JPYC", "JPYC", 6, ADMIN);
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(jpyc), 100_000_000, TRADER);

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.TokenNotEnabled.selector, address(jpyc)));
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnSlippage() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 999_999, TRADER);

        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * 9995 / 10_000;

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.SlippageExceeded.selector, expected, 999_999));
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnInsufficientReserves() public {
        vm.prank(ADMIN);
        executor.withdrawLiquidity(address(eurc), 100e6, ADMIN);

        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 1, TRADER);

        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * 9995 / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(FxSpotExecutor.InsufficientReserves.selector, address(eurc), expected, 0)
        );
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsWhenPaused() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000, TRADER);

        vm.prank(ADMIN);
        executor.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    function test_executeSpotFx_revertsOnUsdcAsTokenOut() public {
        usdc.mint(address(executor), 1e6);
        _setReceipt(REQUEST_ID, 1e6, address(usdc), 900_000, TRADER);

        vm.expectRevert(FxSpotExecutor.UsdcAsTokenOut.selector);
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    /*//////////////////////////////////////////////////////////////
                       v0.1 ADVERSARIAL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Codex CRITICAL — keeper cannot redirect payout to attacker.
    ///         Whatever the keeper supplies as calldata, the executor only
    ///         takes a `requestId` and pays the receipt-stored recipient.
    ///         This test demonstrates the attack vector is closed: the
    ///         keeper has NO context to spoof.
    function test_executeSpotFx_recipientIsCanonicalFromReceipt() public {
        usdc.mint(address(executor), 1e6);
        // Receipt stored with recipient = TRADER (the canonical one).
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000, TRADER);

        // Keeper calls — there's no way to pass a different recipient.
        // The function signature accepts only requestId.
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);

        // Funds go to TRADER, never to OUTSIDER, regardless of who the
        // keeper might have wanted to send them to.
        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * 9995 / 10_000;
        assertEq(eurc.balanceOf(TRADER), expected, "trader (canonical recipient) paid");
        assertEq(eurc.balanceOf(OUTSIDER), 0, "outsider got nothing");
    }

    /// @notice Codex CRITICAL — slippage gate is enforced against the
    ///         canonical receipt.minAmountOut, not anything the keeper passes.
    function test_executeSpotFx_slippageGateIsCanonicalFromReceipt() public {
        usdc.mint(address(executor), 1e6);
        // Set minAmountOut higher than the spread allows.
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 999_999, TRADER);

        uint256 gross = uint256(1e6) * MID_USDC_TO_EURC_E18 / 1e18;
        uint256 expected = gross * 9995 / 10_000;

        // Keeper has no way to override the slippage floor — function takes
        // requestId only.
        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.SlippageExceeded.selector, expected, 999_999));
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);
    }

    /// @notice Codex HIGH#2 — setTokenEnabled rejects tokens whose decimals
    ///         differ from USDC's. Without this guard, 18-dec token math
    ///         underpays by 1e12, 0-dec token math overpays by 1e6.
    function test_setTokenEnabled_revertsOnDecimalsMismatch_18dec() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        vm.expectRevert(
            abi.encodeWithSelector(FxSpotExecutor.TokenOutDecimalsMismatch.selector, address(dai), 6, 18)
        );
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(dai), true);
    }

    function test_setTokenEnabled_revertsOnDecimalsMismatch_0dec() public {
        MockERC20 odd = new MockERC20("ODD", "ODD", 0);
        vm.expectRevert(
            abi.encodeWithSelector(FxSpotExecutor.TokenOutDecimalsMismatch.selector, address(odd), 6, 0)
        );
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(odd), true);
    }

    function test_setTokenEnabled_acceptsMatchingDecimals() public {
        TestnetFiatToken jpyc = new TestnetFiatToken("JPYC", "JPYC", 6, ADMIN);
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(jpyc), true);
        assertTrue(executor.tokenEnabled(address(jpyc)));
    }

    function test_setTokenEnabled_disableDoesNotCheckDecimals() public {
        // Disabling an already-enabled token is always allowed even if
        // decimals were grandfathered (defense-in-depth: lets admin
        // remove a bad token).
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(eurc), false);
        assertFalse(executor.tokenEnabled(address(eurc)));
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
        _setReceipt(REQUEST_ID, 1e6, address(eurc), 900_000, TRADER);

        vm.expectRevert();
        vm.prank(KEEPER);
        executor.executeSpotFx(REQUEST_ID);

        vm.prank(newKeeper);
        executor.executeSpotFx(REQUEST_ID);
        assertTrue(executor.executed(REQUEST_ID));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _baseReceipt(uint256 amount, address tokenOut, uint256 minAmountOut, address recipient)
        internal
        view
        returns (ITelaranaGatewayHubHook.GatewayReceipt memory r)
    {
        r = ITelaranaGatewayHubHook.GatewayReceipt({
            routeId: ROUTE_ID,
            state: ITelaranaGatewayHubHook.GatewayRequestState.MINTED,
            action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX,
            sourceDepositor: TRADER,
            sourceSigner: TRADER,
            recipient: recipient,
            tokenOut: tokenOut,
            amount: amount,
            minAmountOut: minAmountOut,
            spotRouteId: bytes32(0),
            metadataRef: bytes32(0)
        });
    }

    function _setReceipt(bytes32 requestId, uint256 amount, address tokenOut, uint256 minAmountOut, address recipient)
        internal
    {
        tgh.setReceipt(requestId, _baseReceipt(amount, tokenOut, minAmountOut, recipient));
    }
}
