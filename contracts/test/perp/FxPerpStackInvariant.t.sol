// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {FxFundingEngine} from "../../src/perp/FxFundingEngine.sol";
import {FxHealthChecker} from "../../src/perp/FxHealthChecker.sol";
import {FxLiquidationEngine} from "../../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../../src/perp/FxMarginAccount.sol";
import {FxOrderSettlement} from "../../src/perp/FxOrderSettlement.sol";
import {FxPerpClearinghouse} from "../../src/perp/FxPerpClearinghouse.sol";
import {FxPerpMath} from "../../src/perp/FxPerpMath.sol";
import {IFxPerpClearinghouse} from "../../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPerpOracle} from "./FxPerpStack.t.sol";
import {
    FxPerpClearinghouseTestHarness,
    FxHealthCheckerTestHarness,
    FxLiquidationEngineTestHarness
} from "./FxPerpSafetySprint1.t.sol";

contract FxPerpInvariantHandler is Test {
    using SafeCast for uint256;

    MockERC20 internal immutable usdc;
    MockERC20 internal immutable eurc;
    MockPerpOracle internal immutable oracle;
    FxMarginAccount internal immutable margin;
    FxPerpClearinghouse internal immutable clearinghouse;
    FxFundingEngine internal immutable funding;
    FxLiquidationEngine internal immutable liquidation;
    bytes32 internal immutable marketId;
    address internal immutable keeper;
    address[] internal traders;

    constructor(
        MockERC20 usdc_,
        MockERC20 eurc_,
        MockPerpOracle oracle_,
        FxMarginAccount margin_,
        FxPerpClearinghouse clearinghouse_,
        FxFundingEngine funding_,
        FxLiquidationEngine liquidation_,
        bytes32 marketId_,
        address keeper_,
        address[3] memory traders_
    ) {
        usdc = usdc_;
        eurc = eurc_;
        oracle = oracle_;
        margin = margin_;
        clearinghouse = clearinghouse_;
        funding = funding_;
        liquidation = liquidation_;
        marketId = marketId_;
        keeper = keeper_;
        for (uint256 i = 0; i < traders_.length; i++) {
            traders.push(traders_[i]);
        }
    }

    function openLong(uint8 traderIndex, uint96 rawSize) external {
        address trader = traders[uint256(traderIndex) % traders.length];
        uint256 size = bound(uint256(rawSize), 1e15, 5e18);
        vm.prank(keeper);
        try clearinghouse.openOrIncrease(marketId, trader, size.toInt256(), type(uint256).max) {} catch {}
    }

    function closeLong(uint8 traderIndex, uint96 rawSize) external {
        address trader = traders[uint256(traderIndex) % traders.length];
        IFxPerpClearinghouse.Position memory p = clearinghouse.position(marketId, trader);
        if (p.sizeE18 <= 0) return;
        uint256 closeSize = bound(uint256(rawSize), 1, SafeCast.toUint256(p.sizeE18));
        vm.prank(keeper);
        try clearinghouse.decreaseOrClose(marketId, trader, -closeSize.toInt256()) {} catch {}
    }

    function openShort(uint8 traderIndex, uint96 rawSize) external {
        address trader = traders[uint256(traderIndex) % traders.length];
        uint256 size = bound(uint256(rawSize), 1e15, 5e18);
        vm.prank(keeper);
        try clearinghouse.openOrIncrease(marketId, trader, -size.toInt256(), type(uint256).max) {} catch {}
    }

    function closeShort(uint8 traderIndex, uint96 rawSize) external {
        address trader = traders[uint256(traderIndex) % traders.length];
        IFxPerpClearinghouse.Position memory p = clearinghouse.position(marketId, trader);
        if (p.sizeE18 >= 0) return;
        uint256 closeSize = bound(uint256(rawSize), 1, FxPerpMath.abs(p.sizeE18));
        vm.prank(keeper);
        try clearinghouse.decreaseOrClose(marketId, trader, closeSize.toInt256()) {} catch {}
    }

    function settleFunding(uint8 traderIndex, uint16 rawElapsed) external {
        address trader = traders[uint256(traderIndex) % traders.length];
        uint256 elapsed = bound(uint256(rawElapsed), 1, 1 hours);
        vm.warp(block.timestamp + elapsed);
        try funding.settleFunding(marketId, trader) {} catch {}
    }

    function withdrawFreeMargin(uint8 traderIndex, uint96 rawAmount) external {
        address trader = traders[uint256(traderIndex) % traders.length];
        uint256 free = margin.freeMarginOf(trader);
        if (free == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, free);
        vm.prank(trader);
        try margin.withdrawMargin(trader, amount) {} catch {}
    }

    function liquidateIfNeeded(uint8 traderIndex) external {
        address trader = traders[uint256(traderIndex) % traders.length];
        try liquidation.flagAccount(marketId, trader) {}
        catch {
            return;
        }
        try liquidation.liquidate(marketId, trader, type(uint256).max) {} catch {}
    }

    function movePrice(uint96 rawPrice) external {
        uint256 price = bound(uint256(rawPrice), 8e17, 14e17);
        oracle.setMid(address(eurc), address(usdc), price);
    }
}

contract FxPerpStackInvariantTest is StdInvariant, Test {
    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockPerpOracle internal oracle;
    FxMarginAccount internal margin;
    FxPerpClearinghouse internal clearinghouse;
    FxPerpInvariantHandler internal handler;

    address internal constant ADMIN = address(uint160(uint256(keccak256("perp.inv.ADMIN"))));
    address internal constant KEEPER = address(uint160(uint256(keccak256("perp.inv.KEEPER"))));
    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 18);
        oracle = new MockPerpOracle();
        oracle.setMid(address(eurc), address(usdc), 1.1e18);

        vm.startPrank(ADMIN);
        margin = new FxMarginAccount(address(usdc), ADMIN);
        clearinghouse = new FxPerpClearinghouseTestHarness(address(usdc), address(oracle), address(margin), ADMIN);
        FxFundingEngine funding = new FxFundingEngine(address(clearinghouse), address(margin), ADMIN);
        FxHealthChecker health = new FxHealthCheckerTestHarness(address(clearinghouse), address(margin), ADMIN);
        FxLiquidationEngine liquidation =
            new FxLiquidationEngineTestHarness(address(health), address(clearinghouse), address(margin), ADMIN);
        FxOrderSettlement settlement = new FxOrderSettlement(address(clearinghouse), ADMIN);

        clearinghouse.setFundingEngine(address(funding));
        margin.setFundingSettlementHook(address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(funding));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(liquidation));
        clearinghouse.grantRole(clearinghouse.EXECUTOR_ROLE(), KEEPER);
        clearinghouse.grantRole(clearinghouse.ORDER_SETTLEMENT_ROLE(), address(settlement));
        clearinghouse.grantRole(clearinghouse.LIQUIDATION_ENGINE_ROLE(), address(liquidation));
        funding.configureFunding(
            MARKET_ID,
            FxFundingEngine.FundingConfig({enabled: true, maxFundingRateBpsPerSecond: 1, fundingVelocityBps: 1_000})
        );
        liquidation.configureLiquidation(
            FxLiquidationEngine.LiquidationConfig({bountyBps: 1_000, bountyCap: 50e6, flagDelay: 0})
        );
        clearinghouse.configureMarket(
            MARKET_ID,
            IFxPerpClearinghouse.MarketConfig({
                baseToken: address(eurc),
                enabled: true,
                initialMarginBps: 500,
                maintenanceMarginBps: 300,
                tradingFeeBps: 5,
                maxLeverageBps: 200_000,
                maxOpenInterestUsd: 100e6,
                maxSkewUsd: 100e6
            })
        );
        vm.stopPrank();

        address[3] memory traders = [
            address(uint160(uint256(keccak256("perp.inv.TRADER_A")))),
            address(uint160(uint256(keccak256("perp.inv.TRADER_B")))),
            address(uint160(uint256(keccak256("perp.inv.TRADER_C"))))
        ];
        for (uint256 i = 0; i < traders.length; i++) {
            _deposit(traders[i], 1_000e6);
        }
        _seedProtocolLiquidity(10_000e6);

        handler = new FxPerpInvariantHandler(
            usdc, eurc, oracle, margin, clearinghouse, funding, liquidation, MARKET_ID, KEEPER, traders
        );
        targetContract(address(handler));
    }

    function invariant_marginAccountIsCashBacked() public view {
        assertEq(usdc.balanceOf(address(margin)), margin.totalAccountMargin() + margin.protocolLiquidity());
    }

    function invariant_openInterestStaysCapped() public view {
        assertLe(clearinghouse.openInterestLong(MARKET_ID), clearinghouse.maxOpenInterest(MARKET_ID));
        assertLe(clearinghouse.openInterestShort(MARKET_ID), clearinghouse.maxOpenInterest(MARKET_ID));
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
}
