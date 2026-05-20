// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxFundingEngine} from "../../src/perp/FxFundingEngine.sol";
import {FxHealthChecker} from "../../src/perp/FxHealthChecker.sol";
import {FxLiquidationEngine} from "../../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../../src/perp/FxMarginAccount.sol";
import {FxPerpClearinghouse} from "../../src/perp/FxPerpClearinghouse.sol";
import {IFxHealthChecker} from "../../src/perp/interfaces/IFxHealthChecker.sol";
import {IFxOracle} from "../../src/interfaces/IFxOracle.sol";
import {IFxPerpClearinghouse} from "../../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Sprint-1 round-1 HIGH (codex): the production verified-oracle
/// path uses RedStone's `ProxyConnector` to forward the signed payload
/// across contract hops. Building a synthetic payload for unit tests is
/// impractical, so each contract exposes a `virtual` hook (mirror of
/// `FxOracle._redstoneFetch`) that the harness subclasses below override
/// to call the mock oracle / clearinghouse / health checker directly.
contract FxPerpClearinghouseTestHarness is FxPerpClearinghouse {
    constructor(address usdc, address oracle, address marginAccount, address admin)
        FxPerpClearinghouse(usdc, oracle, marginAccount, admin)
    {}

    function _oracleGetMidVerified(address base, address quote)
        internal
        view
        override
        returns (uint256 midE18, uint256 publishedAt)
    {
        return ORACLE.getMidVerified(base, quote);
    }
}

contract FxHealthCheckerTestHarness is FxHealthChecker {
    constructor(address clearinghouse, address marginAccount, address admin)
        FxHealthChecker(clearinghouse, marginAccount, admin)
    {}

    function _clearinghouseUnrealizedPnlVerified(bytes32 marketId, address trader)
        internal
        view
        override
        returns (int256 pnl)
    {
        return CLEARINGHOUSE.unrealizedPnlVerified(marketId, trader);
    }
}

contract FxLiquidationEngineTestHarness is FxLiquidationEngine {
    constructor(address health, address clearinghouse, address marginAccount, address admin)
        FxLiquidationEngine(health, clearinghouse, marginAccount, admin)
    {}

    function _healthIsLiquidatableVerified(bytes32 marketId, address trader)
        internal
        view
        override
        returns (bool liquidatable)
    {
        return HEALTH.isLiquidatableVerified(marketId, trader);
    }

    function _clearinghouseLiquidatePosition(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        internal
        override
        returns (uint256 marginReleased, int256 pnl, uint256 badDebt)
    {
        return CLEARINGHOUSE.liquidatePosition(marketId, trader, maxSizeToCloseAbsE18);
    }
}

/// @notice Mock oracle where `getMid` and `getMidVerified` can diverge.
/// Lets us prove that the liquidation / flag / rescind paths read the
/// strict-oracle entry point — not the lenient one.
contract DivergentOracle is IFxOracle {
    mapping(bytes32 key => uint256 price) public lenientMid;
    mapping(bytes32 key => uint256 price) public verifiedMid;
    mapping(bytes32 key => bool) public verifiedReverts;

    function _key(address base, address quote) internal pure returns (bytes32) {
        return keccak256(abi.encode(base, quote));
    }

    function setLenientMid(address base, address quote, uint256 priceE18) external {
        lenientMid[_key(base, quote)] = priceE18;
    }

    function setVerifiedMid(address base, address quote, uint256 priceE18) external {
        verifiedMid[_key(base, quote)] = priceE18;
    }

    function setBothMid(address base, address quote, uint256 priceE18) external {
        bytes32 k = _key(base, quote);
        lenientMid[k] = priceE18;
        verifiedMid[k] = priceE18;
    }

    function setVerifiedReverts(address base, address quote, bool revertsOn) external {
        verifiedReverts[_key(base, quote)] = revertsOn;
    }

    function getMid(address base, address quote) external view returns (uint256, uint256) {
        uint256 price = lenientMid[_key(base, quote)];
        if (price == 0) revert OracleFeedUnknown(base, quote);
        return (price, block.timestamp);
    }

    function getMidVerified(address base, address quote) external view returns (uint256, uint256) {
        bytes32 k = _key(base, quote);
        if (verifiedReverts[k]) revert OracleDeviation(1e18, 2e18, 5_000, 50);
        uint256 price = verifiedMid[k];
        if (price == 0) revert OracleFeedUnknown(base, quote);
        return (price, block.timestamp);
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

contract FxPerpSafetySprint1Test is Test {
    MockERC20 internal usdc;
    MockERC20 internal eurc;
    DivergentOracle internal oracle;
    FxMarginAccount internal margin;
    FxPerpClearinghouse internal clearinghouse;
    FxFundingEngine internal funding;
    FxHealthChecker internal health;
    FxLiquidationEngine internal liquidation;

    address internal constant ADMIN = address(uint160(uint256(keccak256("safety.ADMIN"))));
    address internal constant KEEPER = address(uint160(uint256(keccak256("safety.KEEPER"))));
    address internal constant TRADER = address(uint160(uint256(keccak256("safety.TRADER"))));
    address internal constant LIQUIDATOR = address(uint160(uint256(keccak256("safety.LIQUIDATOR"))));
    address internal constant FRIEND = address(uint160(uint256(keccak256("safety.FRIEND"))));

    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");
    uint256 internal constant PRICE_HEALTHY = 1.1e18;
    uint256 internal constant PRICE_DIPPED = 0.9e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 18);
        oracle = new DivergentOracle();
        oracle.setBothMid(address(eurc), address(usdc), PRICE_HEALTHY);

        vm.startPrank(ADMIN);
        margin = new FxMarginAccount(address(usdc), ADMIN);
        clearinghouse = new FxPerpClearinghouseTestHarness(address(usdc), address(oracle), address(margin), ADMIN);
        funding = new FxFundingEngine(address(clearinghouse), address(margin), ADMIN);
        health = new FxHealthCheckerTestHarness(address(clearinghouse), address(margin), ADMIN);
        liquidation = new FxLiquidationEngineTestHarness(address(health), address(clearinghouse), address(margin), ADMIN);

        clearinghouse.setFundingEngine(address(funding));
        margin.setFundingSettlementHook(address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(funding));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(liquidation));
        clearinghouse.grantRole(clearinghouse.EXECUTOR_ROLE(), KEEPER);
        clearinghouse.grantRole(clearinghouse.LIQUIDATION_ENGINE_ROLE(), address(liquidation));

        clearinghouse.configureMarket(MARKET_ID, _marketConfig());
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

    // -------- P1 #1: verified-oracle path on flag + liquidate --------

    /// Pyth flicker scenario: lenient says position is liquidatable, verified
    /// (Pyth+RedStone cross-check) says it's not. Flag MUST revert because the
    /// strict path is what controls liquidation.
    function test_p1_1_flagAccount_revertsWhenVerifiedSaysHealthy() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // Lenient dips (Pyth flicker). Verified stays healthy.
        oracle.setLenientMid(address(eurc), address(usdc), PRICE_DIPPED);
        oracle.setVerifiedMid(address(eurc), address(usdc), PRICE_HEALTHY);

        assertTrue(health.isLiquidatable(MARKET_ID, TRADER), "lenient is liquidatable");
        assertFalse(health.isLiquidatableVerified(MARKET_ID, TRADER), "verified is healthy");

        vm.expectRevert(abi.encodeWithSelector(FxLiquidationEngine.AccountHealthy.selector, MARKET_ID, TRADER));
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);
    }

    function test_p1_1_liquidate_refusesWhenVerifiedSaysHealthy() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // Both sources dip → legitimate flag succeeds.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);

        // Verified recovers BEFORE flag delay elapses but lenient stays dipped.
        // After flag delay, liquidate MUST refuse because the verified gate
        // is the controlling read (codex P1 #1). The flag was set during a
        // legitimate dip, so the auto-rescind branch fires: flag cleared,
        // reward zero, no socialized loss.
        oracle.setVerifiedMid(address(eurc), address(usdc), PRICE_HEALTHY);
        vm.warp(block.timestamp + 61);

        assertTrue(health.isLiquidatable(MARKET_ID, TRADER), "lenient still dipped");
        assertFalse(health.isLiquidatableVerified(MARKET_ID, TRADER), "verified healthy");

        vm.prank(LIQUIDATOR);
        (uint256 reward, int256 socializedLoss) = liquidation.liquidate(MARKET_ID, TRADER, 10e18);
        assertEq(reward, 0, "no bounty when verified disagrees");
        assertEq(socializedLoss, 0, "no socialized loss when verified disagrees");
        assertEq(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "flag cleared by auto-rescind");
    }

    /// PnL realization on the liquidation path MUST read the verified oracle.
    /// We force the verified oracle to revert; liquidate must surface that
    /// revert (i.e. the verified read happened).
    function test_p1_1_liquidate_routesPnlThroughVerifiedOracle() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // Lenient + verified agree on the dip → legitimate flag, both gates pass.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);
        vm.warp(block.timestamp + 61);

        // Now arm the verified oracle to revert: liquidate must propagate.
        oracle.setVerifiedReverts(address(eurc), address(usdc), true);

        vm.expectRevert();
        vm.prank(LIQUIDATOR);
        liquidation.liquidate(MARKET_ID, TRADER, 10e18);
    }

    function test_p1_1_unrealizedPnlVerified_usesVerifiedFeed() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // Verified feed shows a profit at 1.20; lenient shows nothing useful (set both, then verify divergence).
        oracle.setLenientMid(address(eurc), address(usdc), PRICE_HEALTHY);
        oracle.setVerifiedMid(address(eurc), address(usdc), 1.2e18);

        int256 pnlLenient = clearinghouse.unrealizedPnl(MARKET_ID, TRADER);
        int256 pnlVerified = clearinghouse.unrealizedPnlVerified(MARKET_ID, TRADER);

        assertEq(pnlLenient, 0, "lenient pnl at entry price = 0");
        assertGt(pnlVerified, 0, "verified pnl is positive");
    }

    function test_p1_1_healthFactorVerified_usesVerifiedFeed() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // Lenient is at the dip (would say unhealthy); verified is healthy.
        oracle.setLenientMid(address(eurc), address(usdc), PRICE_DIPPED);
        oracle.setVerifiedMid(address(eurc), address(usdc), PRICE_HEALTHY);

        uint256 lenientHF = health.healthFactor(MARKET_ID, TRADER);
        uint256 verifiedHF = health.healthFactorVerified(MARKET_ID, TRADER);

        // Verified HF should be strictly higher (healthier) than lenient.
        assertGt(verifiedHF, lenientHF, "verified HF > lenient HF");
    }

    // -------- P1 #5: rescindFlag + auto-rescind --------

    function test_p1_5_rescindFlag_clearsFlagWhenPositionRecovered() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // Legit dip → flag.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);
        assertGt(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "flag exists");

        // Both sources recover; ANY caller can rescind.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_HEALTHY);

        vm.expectEmit(true, true, true, true);
        emit FxLiquidationEngine.AccountFlagRescinded(MARKET_ID, TRADER, FRIEND, false);
        vm.prank(FRIEND);
        liquidation.rescindFlag(MARKET_ID, TRADER);

        assertEq(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "flag cleared");
    }

    function test_p1_5_rescindFlag_revertsWhenStillLiquidatable() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);

        vm.expectRevert(
            abi.encodeWithSelector(FxLiquidationEngine.AccountStillLiquidatable.selector, MARKET_ID, TRADER)
        );
        vm.prank(FRIEND);
        liquidation.rescindFlag(MARKET_ID, TRADER);
    }

    function test_p1_5_rescindFlag_revertsWhenNoFlagExists() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        vm.expectRevert(abi.encodeWithSelector(FxLiquidationEngine.AccountNotFlagged.selector, MARKET_ID, TRADER));
        vm.prank(FRIEND);
        liquidation.rescindFlag(MARKET_ID, TRADER);
    }

    /// The flag-bomb attack: attacker pre-arms during a transient dip, victim
    /// recovers, flagDelay elapses, dip happens again, attacker wants instant
    /// liquidation with no second delay. After the patch, the second-dip
    /// liquidate() call auto-rescinds whenever the position recovered, so the
    /// attacker has to flag fresh and pay the delay again. We exercise the
    /// auto-rescind branch directly: flag + delay elapses + price recovered →
    /// liquidate() clears the flag and returns early with zero reward.
    function test_p1_5_liquidate_autoRescindsWhenPositionRecovered() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // 1. Attacker flags during dip.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);
        assertGt(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "flagged");

        // 2. Price recovers, delay elapses.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_HEALTHY);
        vm.warp(block.timestamp + 61);

        // 3. Attacker fires liquidate. Auto-rescind clears flag + returns early.
        vm.expectEmit(true, true, true, true);
        emit FxLiquidationEngine.AccountFlagRescinded(MARKET_ID, TRADER, LIQUIDATOR, true);
        vm.prank(LIQUIDATOR);
        (uint256 reward, int256 socializedLoss) = liquidation.liquidate(MARKET_ID, TRADER, 10e18);

        assertEq(reward, 0, "auto-rescind pays no bounty");
        assertEq(socializedLoss, 0, "auto-rescind socializes no loss");
        assertEq(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "flag auto-cleared and persists");
    }

    /// Sanity check: when there is NO flag and the position is healthy, the
    /// function still reverts AccountHealthy (auto-rescind only triggers on
    /// the recovery-with-flag path).
    function test_p1_5_liquidate_revertsHealthyWithoutFlag() public {
        _depositAndOpen(TRADER, 1e6, 10e18);
        // No flag exists; position is healthy.
        vm.expectRevert(abi.encodeWithSelector(FxLiquidationEngine.AccountHealthy.selector, MARKET_ID, TRADER));
        vm.prank(LIQUIDATOR);
        liquidation.liquidate(MARKET_ID, TRADER, 10e18);
    }

    function test_p1_5_autoRescind_thenSecondDipNeedsFreshFlagAndDelay() public {
        _depositAndOpen(TRADER, 1e6, 10e18);

        // 1. Flag during dip.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);

        // 2. Recovery, delay elapses, attacker calls liquidate → auto-rescind
        //    returns early; flag is cleared and persists.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_HEALTHY);
        vm.warp(block.timestamp + 61);
        vm.prank(LIQUIDATOR);
        liquidation.liquidate(MARKET_ID, TRADER, 10e18);
        assertEq(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "flag auto-cleared");

        // 3. Second dip. Attacker tries instant liquidate — must fail because
        //    the flag is gone, even though position is now liquidatable.
        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.expectRevert(abi.encodeWithSelector(FxLiquidationEngine.AccountNotFlagged.selector, MARKET_ID, TRADER));
        vm.prank(LIQUIDATOR);
        liquidation.liquidate(MARKET_ID, TRADER, 10e18);

        // 4. Attacker flags fresh; must wait the delay again.
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);
        uint256 flagTs = liquidation.flaggedAt(MARKET_ID, TRADER);
        assertEq(flagTs, block.timestamp, "fresh flag stamped at now");

        vm.expectRevert(
            abi.encodeWithSelector(FxLiquidationEngine.FlagDelayPending.selector, flagTs + 60, block.timestamp)
        );
        vm.prank(LIQUIDATOR);
        liquidation.liquidate(MARKET_ID, TRADER, 10e18);
    }

    function test_p1_5_rescindFlag_paused() public {
        _depositAndOpen(TRADER, 1e6, 10e18);
        oracle.setBothMid(address(eurc), address(usdc), PRICE_DIPPED);
        vm.prank(LIQUIDATOR);
        liquidation.flagAccount(MARKET_ID, TRADER);

        vm.prank(ADMIN);
        liquidation.pause();

        vm.expectRevert();
        vm.prank(FRIEND);
        liquidation.rescindFlag(MARKET_ID, TRADER);
    }

    // -------- helpers --------

    function _marketConfig() internal view returns (IFxPerpClearinghouse.MarketConfig memory) {
        return IFxPerpClearinghouse.MarketConfig({
            baseToken: address(eurc),
            enabled: true,
            initialMarginBps: 500,
            maintenanceMarginBps: 300,
            tradingFeeBps: 5,
            maxLeverageBps: 200_000,
            maxOpenInterestUsd: 1_000_000e6,
            maxSkewUsd: 1_000_000e6
        });
    }

    function _depositAndOpen(address trader, uint256 marginAmount, int256 sizeE18) internal {
        usdc.mint(trader, marginAmount);
        vm.startPrank(trader);
        usdc.approve(address(margin), marginAmount);
        margin.depositMargin(trader, marginAmount);
        vm.stopPrank();

        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, trader, sizeE18, 6_000);
    }

    function _seedProtocolLiquidity(uint256 amount) internal {
        usdc.mint(ADMIN, amount);
        vm.startPrank(ADMIN);
        usdc.approve(address(margin), amount);
        margin.depositProtocolLiquidity(amount);
        vm.stopPrank();
    }
}
