// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {TurboFeeVault} from "../../src/hub/TurboFeeVault.sol";
import {FxFundingEngine} from "../../src/perp/FxFundingEngine.sol";
import {FxHealthChecker} from "../../src/perp/FxHealthChecker.sol";
import {FxLiquidationEngine} from "../../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../../src/perp/FxMarginAccount.sol";
import {FxOrderSettlement} from "../../src/perp/FxOrderSettlement.sol";
import {FxPerpClearinghouse} from "../../src/perp/FxPerpClearinghouse.sol";
import {IFxOracle} from "../../src/interfaces/IFxOracle.sol";
import {IFxOrderSettlement} from "../../src/perp/interfaces/IFxOrderSettlement.sol";
import {IFxPerpClearinghouse} from "../../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {
    FxPerpClearinghouseTestHarness,
    FxHealthCheckerTestHarness,
    FxLiquidationEngineTestHarness
} from "./FxPerpSafetySprint1.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MockPerpOracle is IFxOracle {
    mapping(bytes32 key => uint256 price) public mid;

    function setMid(address base, address quote, uint256 priceE18) external {
        mid[keccak256(abi.encode(base, quote))] = priceE18;
    }

    function getMid(address base, address quote) external view returns (uint256, uint256) {
        uint256 price = mid[keccak256(abi.encode(base, quote))];
        if (price == 0) revert OracleFeedUnknown(base, quote);
        return (price, block.timestamp);
    }

    function getMidVerified(address base, address quote) external view returns (uint256, uint256) {
        return this.getMid(base, quote);
    }

    function getMidWithUpdate(address, address, bytes[] calldata) external payable returns (uint256, uint256) {
        revert("unused");
    }

    function getMidWithUpdatePyth(address, address, bytes[] calldata) external payable returns (uint256, uint256) {
        revert("unused");
    }

    function priceOf(address) external pure returns (uint256, uint256) {
        revert("unused");
    }

    function config() external pure returns (uint256, uint256, uint256) {
        return (60, 50, 30);
    }
}

contract LocalMatcherRelay {
    IFxOrderSettlement public immutable settlement;

    constructor(IFxOrderSettlement settlement_) {
        settlement = settlement_;
    }

    function settleMatched(
        IFxOrderSettlement.SignedOrder calldata makerOrder,
        bytes calldata makerSig,
        IFxOrderSettlement.SignedOrder calldata takerOrder,
        bytes calldata takerSig,
        uint256 fillSizeE18,
        uint256 fillPriceE18
    ) external {
        settlement.settleMatch(makerOrder, makerSig, takerOrder, takerSig, fillSizeE18, fillPriceE18);
    }
}

contract FxPerpStackTest is Test {
    using SafeCast for uint256;

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockPerpOracle internal oracle;
    FxMarginAccount internal margin;
    FxPerpClearinghouse internal clearinghouse;
    FxFundingEngine internal funding;
    FxHealthChecker internal health;
    FxLiquidationEngine internal liquidation;
    FxOrderSettlement internal settlement;

    address internal constant ADMIN = address(uint160(uint256(keccak256("perp.ADMIN"))));
    address internal constant KEEPER = address(uint160(uint256(keccak256("perp.KEEPER"))));
    address internal constant TRADER = address(uint160(uint256(keccak256("perp.TRADER"))));
    address internal constant LIQUIDATOR = address(uint160(uint256(keccak256("perp.LIQUIDATOR"))));
    uint256 internal constant MAKER_PK = 0xA11CE;
    uint256 internal constant TAKER_PK = 0xB0B;
    address internal maker;
    address internal taker;

    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");
    uint256 internal constant PRICE_1_10 = 1_100_000_000_000_000_000;

    function setUp() public {
        maker = vm.addr(MAKER_PK);
        taker = vm.addr(TAKER_PK);

        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 18);
        oracle = new MockPerpOracle();
        oracle.setMid(address(eurc), address(usdc), PRICE_1_10);

        vm.startPrank(ADMIN);
        margin = new FxMarginAccount(address(usdc), ADMIN);
        clearinghouse = new FxPerpClearinghouseTestHarness(address(usdc), address(oracle), address(margin), ADMIN);
        funding = new FxFundingEngine(address(clearinghouse), address(margin), ADMIN);
        health = new FxHealthCheckerTestHarness(address(clearinghouse), address(margin), ADMIN);
        liquidation =
            new FxLiquidationEngineTestHarness(address(health), address(clearinghouse), address(margin), ADMIN);
        settlement = new FxOrderSettlement(address(clearinghouse), ADMIN);

        clearinghouse.setFundingEngine(address(funding));
        margin.setFundingSettlementHook(address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(funding));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(liquidation));
        margin.grantRole(margin.ACCOUNT_OPERATOR_ROLE(), KEEPER);
        clearinghouse.grantRole(clearinghouse.EXECUTOR_ROLE(), KEEPER);
        clearinghouse.grantRole(clearinghouse.ORDER_SETTLEMENT_ROLE(), address(settlement));
        clearinghouse.grantRole(clearinghouse.LIQUIDATION_ENGINE_ROLE(), address(liquidation));
        settlement.grantRole(settlement.SETTLER_ROLE(), KEEPER);

        clearinghouse.configureMarket(MARKET_ID, _marketConfig(1_000_000e6, 1_000_000e6));
        funding.configureFunding(
            MARKET_ID,
            FxFundingEngine.FundingConfig({enabled: true, maxFundingRateBpsPerSecond: 1, fundingVelocityBps: 1_000})
        );
        liquidation.configureLiquidation(
            FxLiquidationEngine.LiquidationConfig({bountyBps: 1_000, bountyCap: 50e6, flagDelay: 60})
        );
        vm.stopPrank();

        _seedProtocolLiquidity(1_000e6);
    }

    function test_openIncreaseReservesMarginAndChargesFee() public {
        _deposit(TRADER, 100e6);

        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);

        IFxPerpClearinghouse.Position memory p = clearinghouse.position(MARKET_ID, TRADER);
        assertEq(p.sizeE18, 10e18, "size");
        assertEq(p.entryPriceE18, PRICE_1_10, "entry");
        assertEq(p.marginReserved, 550_000, "reserved");
        assertEq(margin.marginOf(TRADER), 99_994_500, "fee charged");
        assertEq(margin.protocolLiquidity(), 1_000e6 + 5_500, "fee to protocol bucket");
        assertEq(clearinghouse.openInterestLong(MARKET_ID), 11e6, "long OI");
    }

    function test_openIncreaseRoutesFeeToTurboFeeVaultWhenConfigured() public {
        TurboFeeVault vault = new TurboFeeVault(IERC20(address(usdc)), ADMIN);
        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), address(clearinghouse));
        vm.prank(ADMIN);
        clearinghouse.setFeeVault(address(vault));

        _deposit(TRADER, 100e6);

        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);

        assertEq(margin.marginOf(TRADER), 99_994_500, "fee charged");
        assertEq(margin.protocolLiquidity(), 1_000e6, "fee bypasses protocol bucket");
        assertEq(vault.totalFeesCollected(), 5_500, "vault fee total");
        assertEq(usdc.balanceOf(ADMIN), 2_750, "protocol split");
        assertEq(vault.insuranceBalance(), 2_750, "insurance plus no-LP yield");
        assertEq(usdc.balanceOf(address(vault)), 2_750, "vault retained balance");
    }

    function test_increaseLongWeightedEntry() public {
        _deposit(TRADER, 100e6);
        vm.startPrank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
        oracle.setMid(address(eurc), address(usdc), 1.2e18);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
        vm.stopPrank();

        IFxPerpClearinghouse.Position memory p = clearinghouse.position(MARKET_ID, TRADER);
        assertEq(p.sizeE18, 20e18);
        assertEq(p.entryPriceE18, 1.15e18);
    }

    function test_decreaseRealizesProfitAndReleasesMargin() public {
        _deposit(TRADER, 100e6);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
        oracle.setMid(address(eurc), address(usdc), 1.2e18);

        vm.prank(KEEPER);
        uint256 released = clearinghouse.decreaseOrClose(MARKET_ID, TRADER, -5e18);

        assertEq(released, 275_000, "released");
        assertEq(margin.marginOf(TRADER), 100_494_500, "profit added");
        IFxPerpClearinghouse.Position memory p = clearinghouse.position(MARKET_ID, TRADER);
        assertEq(p.sizeE18, 5e18, "remaining size");
        assertEq(p.marginReserved, 275_000, "remaining reserved");
    }

    function test_revertsWhenOiCapExceeded() public {
        vm.prank(ADMIN);
        clearinghouse.configureMarket(MARKET_ID, _marketConfig(5e6, 5e6));
        _deposit(TRADER, 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(FxPerpClearinghouse.OpenInterestCapExceeded.selector, MARKET_ID, 11e6, 5e6)
        );
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
    }

    function test_revertsOnInsufficientMargin() public {
        _deposit(TRADER, 100_000);

        vm.expectRevert();
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
    }

    function test_pauseBlocksClearinghouseMutation() public {
        _deposit(TRADER, 100e6);
        vm.prank(ADMIN);
        clearinghouse.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
    }

    function test_healthAndLiquidationCloseUnhealthyPosition() public {
        _deposit(TRADER, 1e6);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);

        oracle.setMid(address(eurc), address(usdc), 0.9e18);
        assertTrue(health.isLiquidatable(MARKET_ID, TRADER), "liquidatable");

        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);
        vm.warp(block.timestamp + liquidation.MIN_LIQUIDATION_FLAG_DELAY());
        vm.prank(LIQUIDATOR);
        (, int256 socializedLoss) = liquidation.liquidate(MARKET_ID, TRADER, 10e18);

        assertGt(socializedLoss, 0, "bad debt socialized");
        IFxPerpClearinghouse.Position memory p = clearinghouse.position(MARKET_ID, TRADER);
        assertEq(p.sizeE18, 0, "closed");
    }

    function test_orderSettlementMatchesSignedLimitOrders() public {
        _deposit(maker, 100e6);
        _deposit(taker, 100e6);

        IFxOrderSettlement.SignedOrder memory makerOrder = IFxOrderSettlement.SignedOrder({
            trader: maker,
            marketId: MARKET_ID,
            sizeDeltaE18: 5e18,
            priceE18: PRICE_1_10,
            maxFee: 10_000,
            orderType: settlement.ORDER_TYPE_LIMIT(),
            flags: settlement.FLAG_POST_ONLY(),
            nonce: 1,
            deadline: uint64(block.timestamp + 1 hours)
        });
        IFxOrderSettlement.SignedOrder memory takerOrder = IFxOrderSettlement.SignedOrder({
            trader: taker,
            marketId: MARKET_ID,
            sizeDeltaE18: -5e18,
            priceE18: PRICE_1_10,
            maxFee: 10_000,
            orderType: settlement.ORDER_TYPE_LIMIT(),
            flags: 0,
            nonce: 2,
            deadline: uint64(block.timestamp + 1 hours)
        });

        bytes memory makerSig = _signOrder(MAKER_PK, makerOrder);
        bytes memory takerSig = _signOrder(TAKER_PK, takerOrder);

        vm.prank(KEEPER);
        settlement.settleMatch(makerOrder, makerSig, takerOrder, takerSig, 5e18, PRICE_1_10);

        assertEq(clearinghouse.position(MARKET_ID, maker).sizeE18, 5e18, "maker long");
        assertEq(clearinghouse.position(MARKET_ID, taker).sizeE18, -5e18, "taker short");

        vm.expectRevert(abi.encodeWithSelector(FxOrderSettlement.NonceAlreadyUsed.selector, maker, uint64(1)));
        vm.prank(KEEPER);
        settlement.settleMatch(makerOrder, makerSig, takerOrder, takerSig, 5e18, PRICE_1_10);
    }

    function test_localMatcherRelaySettlesSignedOrdersThroughSettlement() public {
        _deposit(maker, 100e6);
        _deposit(taker, 100e6);

        LocalMatcherRelay relay = new LocalMatcherRelay(IFxOrderSettlement(address(settlement)));
        bytes32 settlerRole = settlement.SETTLER_ROLE();
        vm.prank(ADMIN);
        settlement.grantRole(settlerRole, address(relay));

        IFxOrderSettlement.SignedOrder memory makerOrder = IFxOrderSettlement.SignedOrder({
            trader: maker,
            marketId: MARKET_ID,
            sizeDeltaE18: 5e18,
            priceE18: PRICE_1_10,
            maxFee: 10_000,
            orderType: settlement.ORDER_TYPE_LIMIT(),
            flags: settlement.FLAG_POST_ONLY(),
            nonce: 21,
            deadline: uint64(block.timestamp + 1 hours)
        });
        IFxOrderSettlement.SignedOrder memory takerOrder = IFxOrderSettlement.SignedOrder({
            trader: taker,
            marketId: MARKET_ID,
            sizeDeltaE18: -5e18,
            priceE18: PRICE_1_10,
            maxFee: 10_000,
            orderType: settlement.ORDER_TYPE_LIMIT(),
            flags: 0,
            nonce: 22,
            deadline: uint64(block.timestamp + 1 hours)
        });

        relay.settleMatched(
            makerOrder, _signOrder(MAKER_PK, makerOrder), takerOrder, _signOrder(TAKER_PK, takerOrder), 5e18, PRICE_1_10
        );

        assertEq(clearinghouse.position(MARKET_ID, maker).sizeE18, 5e18, "maker long via matcher relay");
        assertEq(clearinghouse.position(MARKET_ID, taker).sizeE18, -5e18, "taker short via matcher relay");
        assertEq(settlement.nonceBitmap(maker, 0) & (1 << 21), 1 << 21, "maker nonce consumed");
        assertEq(settlement.nonceBitmap(taker, 0) & (1 << 22), 1 << 22, "taker nonce consumed");
    }

    function test_orderSettlementHonorsSignedMaxFee() public {
        _deposit(maker, 100e6);
        _deposit(taker, 100e6);

        IFxOrderSettlement.SignedOrder memory makerOrder = IFxOrderSettlement.SignedOrder({
            trader: maker,
            marketId: MARKET_ID,
            sizeDeltaE18: 5e18,
            priceE18: PRICE_1_10,
            maxFee: 1,
            orderType: settlement.ORDER_TYPE_LIMIT(),
            flags: settlement.FLAG_POST_ONLY(),
            nonce: 11,
            deadline: uint64(block.timestamp + 1 hours)
        });
        IFxOrderSettlement.SignedOrder memory takerOrder = IFxOrderSettlement.SignedOrder({
            trader: taker,
            marketId: MARKET_ID,
            sizeDeltaE18: -5e18,
            priceE18: PRICE_1_10,
            maxFee: 10_000,
            orderType: settlement.ORDER_TYPE_LIMIT(),
            flags: 0,
            nonce: 12,
            deadline: uint64(block.timestamp + 1 hours)
        });

        bytes memory makerSig = _signOrder(MAKER_PK, makerOrder);
        bytes memory takerSig = _signOrder(TAKER_PK, takerOrder);

        vm.expectRevert(abi.encodeWithSelector(FxPerpClearinghouse.SlippageFeeExceeded.selector, 2_750, 1));
        vm.prank(KEEPER);
        settlement.settleMatch(makerOrder, makerSig, takerOrder, takerSig, 5e18, PRICE_1_10);
    }

    function test_fundingSettlesLongHeavySkew() public {
        vm.prank(ADMIN);
        clearinghouse.configureMarket(MARKET_ID, _marketConfig(100e6, 100e6));
        _deposit(TRADER, 100e6);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
        funding.pokeFundingRate(MARKET_ID);

        uint256 beforeMargin = margin.marginOf(TRADER);
        vm.warp(block.timestamp + 1 hours);
        funding.settleFunding(MARKET_ID, TRADER);
        assertLt(margin.marginOf(TRADER), beforeMargin, "long-heavy funding charges long");
    }

    function test_closeSettlesFundingBeforePositionClears() public {
        vm.prank(ADMIN);
        clearinghouse.configureMarket(MARKET_ID, _marketConfig(100e6, 100e6));
        _deposit(TRADER, 100e6);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
        funding.pokeFundingRate(MARKET_ID);

        uint256 beforeMargin = margin.marginOf(TRADER);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(KEEPER);
        clearinghouse.decreaseOrClose(MARKET_ID, TRADER, -10e18);

        (,,, int256 latestIndex) = funding.fundingState(MARKET_ID);
        assertEq(funding.traderFundingIndex(MARKET_ID, TRADER), latestIndex, "funding index settled");
        assertLt(margin.marginOf(TRADER), beforeMargin, "funding charged before close");
        assertEq(clearinghouse.position(MARKET_ID, TRADER).sizeE18, 0, "position closed");
    }

    function test_withdrawSettlesFundingBeforeFreeMarginCheck() public {
        vm.prank(ADMIN);
        clearinghouse.configureMarket(MARKET_ID, _marketConfig(100e6, 100e6));
        _deposit(TRADER, 100e6);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
        funding.pokeFundingRate(MARKET_ID);

        uint256 beforeMargin = margin.marginOf(TRADER);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(TRADER);
        margin.withdrawMargin(TRADER, 1);

        (,,, int256 latestIndex) = funding.fundingState(MARKET_ID);
        assertEq(funding.traderFundingIndex(MARKET_ID, TRADER), latestIndex, "funding index settled");
        assertLt(margin.marginOf(TRADER), beforeMargin - 1, "funding charged before withdrawal");
    }

    function testFuzz_requiredMarginUsesConfiguredInitialMargin(uint96 rawSize, uint96 rawPrice) public {
        uint256 size = bound(uint256(rawSize), 1e15, 1_000e18);
        uint256 price = bound(uint256(rawPrice), 1e17, 2e18);
        oracle.setMid(address(eurc), address(usdc), price);
        uint256 notionalE18 = size * price / 1e18;
        uint256 notional = notionalE18 / 1e12;
        uint256 expectedMargin = notional * 500 / 10_000;
        uint256 maxFee = notional;

        _deposit(TRADER, notional + 100e6);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, size.toInt256(), maxFee);

        assertEq(clearinghouse.position(MARKET_ID, TRADER).marginReserved, expectedMargin);
    }

    function _marketConfig(uint256 maxOi, uint256 maxSkew)
        internal
        view
        returns (IFxPerpClearinghouse.MarketConfig memory)
    {
        return IFxPerpClearinghouse.MarketConfig({
            baseToken: address(eurc),
            enabled: true,
            initialMarginBps: 500,
            maintenanceMarginBps: 300,
            tradingFeeBps: 5,
            maxLeverageBps: 200_000,
            maxOpenInterestUsd: maxOi,
            maxSkewUsd: maxSkew
        });
    }

    function _deposit(address trader, uint256 amount) internal {
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(margin), amount);
        margin.depositMargin(trader, amount);
        vm.stopPrank();
    }

    function _seedProtocolLiquidity(uint256 amount) internal {
        usdc.mint(ADMIN, amount);
        vm.startPrank(ADMIN);
        usdc.approve(address(margin), amount);
        margin.depositProtocolLiquidity(amount);
        vm.stopPrank();
    }

    function _signOrder(uint256 pk, IFxOrderSettlement.SignedOrder memory order) internal view returns (bytes memory) {
        bytes32 digest = settlement.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
