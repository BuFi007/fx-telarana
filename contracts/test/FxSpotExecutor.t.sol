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
    uint256 public settledCount;

    function setReceipt(bytes32 requestId, GatewayReceipt memory r) external {
        _receipts[requestId] = r;
    }

    function gatewayReceipt(bytes32 requestId) external view returns (GatewayReceipt memory) {
        return _receipts[requestId];
    }

    function markGatewayAtomicFxSwapSettled(
        bytes32 requestId,
        uint256 /*amountOut*/
    )
        external
    {
        GatewayReceipt storage r = _receipts[requestId];
        require(r.state == GatewayRequestState.MINTED, "not minted");
        require(r.action == GatewayHubAction.MINT_AND_REQUEST_SPOT_FX, "not spot fx");
        r.state = GatewayRequestState.SETTLED;
        settled[requestId] = true;
        settledCount++;
    }

    function gatewayRoute(bytes32) external pure returns (GatewayHubRoute memory r) {
        return r;
    }

    function gatewayRequestState(bytes32 requestId) external view returns (GatewayRequestState) {
        return _receipts[requestId].state;
    }

    function setGatewayRoute(bytes32, GatewayHubRoute calldata) external pure {
        revert("unused");
    }

    function setGatewaySignerMode(bytes32, GatewaySignerMode, bool) external pure {
        revert("unused");
    }

    function receiveGatewayMint(bytes calldata, bytes calldata, GatewayMintContext calldata)
        external
        pure
        returns (uint256)
    {
        revert("unused");
    }
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
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, executor.EXECUTOR_ROLE()
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

    /// @notice Codex HIGH#2 v0.2 follow-up — setTokenEnabled stores token
    ///         decimals so executeSpotFx can scale payout math correctly.
    function test_setTokenEnabled_acceptsAndStores18Decimals() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(dai), true);
        assertTrue(executor.tokenEnabled(address(dai)));
        assertEq(executor.tokenDecimals(address(dai)), 18);
    }

    function test_setTokenEnabled_acceptsAndStores8Decimals() public {
        MockERC20 jpy = new MockERC20("JPY", "JPY", 8);
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(jpy), true);
        assertTrue(executor.tokenEnabled(address(jpy)));
        assertEq(executor.tokenDecimals(address(jpy)), 8);
    }

    function test_setTokenEnabled_acceptsMatchingDecimals() public {
        TestnetFiatToken jpyc = new TestnetFiatToken("JPYC", "JPYC", 6, ADMIN);
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(jpyc), true);
        assertTrue(executor.tokenEnabled(address(jpyc)));
        assertEq(executor.tokenDecimals(address(jpyc)), 6);
    }

    function test_setTokenEnabled_disableClearsStoredDecimals() public {
        vm.prank(ADMIN);
        executor.setTokenEnabled(address(eurc), false);
        assertFalse(executor.tokenEnabled(address(eurc)));
        assertEq(executor.tokenDecimals(address(eurc)), 0);
    }

    function test_executeSpotFx_scalesSixDecimalUsdcTo18DecimalTokenOut() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        uint256 midE18 = 2.5e18;
        uint256 amountIn = 1e6;

        vm.prank(ADMIN);
        executor.setTokenEnabled(address(dai), true);
        oracle.setMid(address(usdc), address(dai), midE18);

        uint256 expected = _quote(amountIn, midE18, 5, usdc.decimals(), dai.decimals());
        usdc.mint(address(executor), amountIn);
        dai.mint(address(executor), expected);
        _setReceipt(REQUEST_ID, amountIn, address(dai), expected, TRADER);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(REQUEST_ID);

        assertEq(amountOut, expected);
        assertEq(dai.balanceOf(TRADER), 2_498_750_000_000_000_000);
    }

    function test_executeSpotFx_scalesSixDecimalUsdcTo8DecimalTokenOut() public {
        MockERC20 jpy = new MockERC20("JPY", "JPY", 8);
        uint256 midE18 = 156.25e18;
        uint256 amountIn = 1e6;

        vm.prank(ADMIN);
        executor.setTokenEnabled(address(jpy), true);
        oracle.setMid(address(usdc), address(jpy), midE18);

        uint256 expected = _quote(amountIn, midE18, 5, usdc.decimals(), jpy.decimals());
        usdc.mint(address(executor), amountIn);
        jpy.mint(address(executor), expected);
        _setReceipt(REQUEST_ID, amountIn, address(jpy), expected, TRADER);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(REQUEST_ID);

        assertEq(amountOut, expected);
        assertEq(jpy.balanceOf(TRADER), 15_617_187_500);
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
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_executeSpotFx_matchesOracleSpreadQuote(uint96 rawAmount, uint96 rawMid, uint16 rawSpread) public {
        uint256 amount = bound(uint256(rawAmount), 1, 10_000_000e6);
        uint256 midE18 = bound(uint256(rawMid), 1e14, 5e18);
        uint256 spreadBps = bound(uint256(rawSpread), 0, 500);
        bytes32 requestId = keccak256(abi.encode("spot.fuzz.quote", amount, midE18, spreadBps));

        oracle.setMid(address(usdc), address(eurc), midE18);
        vm.prank(ADMIN);
        executor.setDefaultSpreadBps(spreadBps);

        uint256 expected = _quote(amount, midE18, spreadBps, usdc.decimals(), eurc.decimals());
        usdc.mint(address(executor), amount);
        eurc.mint(address(executor), expected);
        _setReceipt(requestId, amount, address(eurc), expected, TRADER);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(requestId);

        assertEq(amountOut, expected, "amountOut");
        assertEq(eurc.balanceOf(TRADER), expected, "recipient payout");
        assertEq(usdc.balanceOf(address(executor)), amount, "USDC retained");
        assertTrue(tgh.settled(requestId), "TGH settled");
    }

    function testFuzz_executeSpotFx_revertsWhenCanonicalMinExceedsQuote(
        uint96 rawAmount,
        uint96 rawMid,
        uint16 rawSpread
    ) public {
        uint256 amount = bound(uint256(rawAmount), 1, 10_000_000e6);
        uint256 midE18 = bound(uint256(rawMid), 1e14, 5e18);
        uint256 spreadBps = bound(uint256(rawSpread), 0, 500);
        bytes32 requestId = keccak256(abi.encode("spot.fuzz.slippage", amount, midE18, spreadBps));

        oracle.setMid(address(usdc), address(eurc), midE18);
        vm.prank(ADMIN);
        executor.setDefaultSpreadBps(spreadBps);

        uint256 expected = _quote(amount, midE18, spreadBps, usdc.decimals(), eurc.decimals());
        uint256 minAmountOut = expected + 1;
        usdc.mint(address(executor), amount);
        eurc.mint(address(executor), expected);
        _setReceipt(requestId, amount, address(eurc), minAmountOut, TRADER);

        vm.expectRevert(abi.encodeWithSelector(FxSpotExecutor.SlippageExceeded.selector, expected, minAmountOut));
        vm.prank(KEEPER);
        executor.executeSpotFx(requestId);
    }

    function testFuzz_setTokenEnabled_storesTokenDecimals(uint8 rawDecimals) public {
        uint8 decimals_ = uint8(bound(uint256(rawDecimals), 0, executor.MAX_TOKEN_DECIMALS()));
        MockERC20 token = new MockERC20("FUZZ", "FUZZ", decimals_);

        vm.prank(ADMIN);
        executor.setTokenEnabled(address(token), true);

        assertTrue(executor.tokenEnabled(address(token)));
        assertEq(executor.tokenDecimals(address(token)), decimals_);
    }

    function testFuzz_executeSpotFx_matchesDecimalScaledQuote(
        uint96 rawAmount,
        uint96 rawMid,
        uint16 rawSpread,
        uint8 rawDecimals
    ) public {
        uint8 outDecimals = uint8(bound(uint256(rawDecimals), 0, 18));
        MockERC20 tokenOut = new MockERC20("FX", "FX", outDecimals);
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000e6);
        uint256 midE18 = bound(uint256(rawMid), 1e14, 500e18);
        uint256 spreadBps = bound(uint256(rawSpread), 0, 500);
        bytes32 requestId = keccak256(abi.encode("spot.fuzz.decimals", amount, midE18, spreadBps, outDecimals));

        vm.startPrank(ADMIN);
        executor.setTokenEnabled(address(tokenOut), true);
        executor.setDefaultSpreadBps(spreadBps);
        vm.stopPrank();
        oracle.setMid(address(usdc), address(tokenOut), midE18);

        uint256 expected = _quote(amount, midE18, spreadBps, usdc.decimals(), tokenOut.decimals());
        usdc.mint(address(executor), amount);
        tokenOut.mint(address(executor), expected);
        _setReceipt(requestId, amount, address(tokenOut), expected, TRADER);

        vm.prank(KEEPER);
        uint256 amountOut = executor.executeSpotFx(requestId);

        assertEq(amountOut, expected, "decimal-scaled amountOut");
        assertEq(tokenOut.balanceOf(TRADER), expected, "decimal-scaled payout");
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

    function _quote(uint256 amount, uint256 midE18, uint256 spreadBps, uint8 inDecimals, uint8 outDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInE18 = _scaleDecimals(amount, inDecimals, 18);
        uint256 grossE18 = amountInE18 * midE18 / 1e18;
        uint256 gross = _scaleDecimals(grossE18, 18, outDecimals);
        return gross * (10_000 - spreadBps) / 10_000;
    }

    function _scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount * (10 ** uint256(toDecimals - fromDecimals));
        return amount / (10 ** uint256(fromDecimals - toDecimals));
    }
}

contract FxSpotExecutorInvariantHandler {
    FxSpotExecutor public immutable executor;
    MockFxOracle public immutable oracle;
    MockTelaranaGatewayHubHook public immutable tgh;
    MockERC20 public immutable usdc;
    MockERC20 public immutable eurc;
    address public immutable recipientA;
    address public immutable recipientB;

    uint256 public totalUsdcMinted;
    uint256 public totalTokenOutSeeded;
    uint256 public totalTokenOutPaid;
    uint256 public executions;

    error UnexpectedAmountOut(uint256 actual, uint256 expected);

    constructor(
        FxSpotExecutor executor_,
        MockFxOracle oracle_,
        MockTelaranaGatewayHubHook tgh_,
        MockERC20 usdc_,
        MockERC20 eurc_,
        address recipientA_,
        address recipientB_
    ) {
        executor = executor_;
        oracle = oracle_;
        tgh = tgh_;
        usdc = usdc_;
        eurc = eurc_;
        recipientA = recipientA_;
        recipientB = recipientB_;
    }

    function execute(uint256 rawAmount, uint256 rawMid, uint16 rawSpread, uint256 rawMinDiscount, bool secondRecipient)
        external
    {
        uint256 amount = _bound(rawAmount, 1, 1_000_000e6);
        uint256 midE18 = _bound(rawMid, 1e14, 5e18);
        uint256 spreadBps = _bound(uint256(rawSpread), 0, 500);
        uint256 expected = _quote(amount, midE18, spreadBps, usdc.decimals(), eurc.decimals());
        uint256 minDiscount = expected == 0 ? 0 : _bound(rawMinDiscount, 0, expected);
        uint256 minAmountOut = expected - minDiscount;
        address recipient = secondRecipient ? recipientB : recipientA;
        bytes32 requestId =
            keccak256(abi.encode(address(this), executions, amount, midE18, spreadBps, minAmountOut, recipient));

        oracle.setMid(address(usdc), address(eurc), midE18);
        executor.setDefaultSpreadBps(spreadBps);

        usdc.mint(address(executor), amount);
        totalUsdcMinted += amount;

        uint256 reserve = eurc.balanceOf(address(executor));
        if (reserve < expected) {
            uint256 topUp = expected - reserve;
            eurc.mint(address(executor), topUp);
            totalTokenOutSeeded += topUp;
        }

        tgh.setReceipt(
            requestId,
            ITelaranaGatewayHubHook.GatewayReceipt({
                routeId: keccak256("spot.invariant.route"),
                state: ITelaranaGatewayHubHook.GatewayRequestState.MINTED,
                action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX,
                sourceDepositor: recipient,
                sourceSigner: recipient,
                recipient: recipient,
                tokenOut: address(eurc),
                amount: amount,
                minAmountOut: minAmountOut,
                spotRouteId: bytes32(0),
                metadataRef: bytes32(0)
            })
        );

        uint256 amountOut = executor.executeSpotFx(requestId);
        if (amountOut != expected) revert UnexpectedAmountOut(amountOut, expected);

        totalTokenOutPaid += amountOut;
        executions++;
    }

    function _quote(uint256 amount, uint256 midE18, uint256 spreadBps, uint8 inDecimals, uint8 outDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInE18 = _scaleDecimals(amount, inDecimals, 18);
        uint256 grossE18 = amountInE18 * midE18 / 1e18;
        uint256 gross = _scaleDecimals(grossE18, 18, outDecimals);
        return gross * (10_000 - spreadBps) / 10_000;
    }

    function _scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount * (10 ** uint256(toDecimals - fromDecimals));
        return amount / (10 ** uint256(fromDecimals - toDecimals));
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        if (x < min) return min;
        if (x > max) return min + (x % (max - min + 1));
        return x;
    }
}

/// @notice Stateful v0.2 invariants for the receipt-canonical spot executor.
///         The handler runs only valid TGH receipts. Invariants assert that
///         USDC delivered by TGH remains in the executor, tokenOut payouts are
///         conserved against seeded reserves, and every execution settles TGH.
contract FxSpotExecutorInvariantTest is Test {
    FxSpotExecutor public executor;
    MockFxOracle public oracle;
    MockTelaranaGatewayHubHook public tgh;
    MockERC20 public usdc;
    MockERC20 public eurc;
    FxSpotExecutorInvariantHandler public handler;

    address internal constant ADMIN = address(uint160(uint256(keccak256("spot.invariant.ADMIN"))));
    address internal constant RECIPIENT_A = address(uint160(uint256(keccak256("spot.invariant.RECIPIENT_A"))));
    address internal constant RECIPIENT_B = address(uint160(uint256(keccak256("spot.invariant.RECIPIENT_B"))));

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        oracle = new MockFxOracle();
        tgh = new MockTelaranaGatewayHubHook();

        executor = new FxSpotExecutor(address(usdc), address(oracle), address(tgh), ADMIN, 5);

        vm.startPrank(ADMIN);
        executor.setTokenEnabled(address(eurc), true);
        vm.stopPrank();

        handler = new FxSpotExecutorInvariantHandler({
            executor_: executor,
            oracle_: oracle,
            tgh_: tgh,
            usdc_: usdc,
            eurc_: eurc,
            recipientA_: RECIPIENT_A,
            recipientB_: RECIPIENT_B
        });

        vm.startPrank(ADMIN);
        executor.grantRole(executor.DEFAULT_ADMIN_ROLE(), address(handler));
        executor.grantRole(executor.EXECUTOR_ROLE(), address(handler));
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FxSpotExecutorInvariantHandler.execute.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_usdcDeliveredByTghRemainsInExecutor() public view {
        assertEq(usdc.balanceOf(address(executor)), handler.totalUsdcMinted(), "USDC accounting drift");
    }

    function invariant_tokenOutPayoutsConservedAgainstSeededReserves() public view {
        uint256 recipientBalances = eurc.balanceOf(RECIPIENT_A) + eurc.balanceOf(RECIPIENT_B);
        assertEq(recipientBalances, handler.totalTokenOutPaid(), "recipient payout drift");
        assertEq(
            eurc.balanceOf(address(executor)) + recipientBalances,
            handler.totalTokenOutSeeded(),
            "tokenOut conservation drift"
        );
    }

    function invariant_eachSuccessfulExecutionSettlesTghReceipt() public view {
        assertEq(tgh.settledCount(), handler.executions(), "settlement count drift");
    }
}
