// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquidationRouter} from "../../src/perp/LiquidationRouter.sol";
import {FxFundingEngine} from "../../src/perp/FxFundingEngine.sol";
import {FxHealthChecker} from "../../src/perp/FxHealthChecker.sol";
import {FxLiquidationEngine} from "../../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../../src/perp/FxMarginAccount.sol";
import {IFxLiquidationEngine} from "../../src/perp/interfaces/IFxLiquidationEngine.sol";
import {IFxPerpClearinghouse} from "../../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPerpOracle} from "./FxPerpStack.t.sol";
import {
    FxPerpClearinghouseTestHarness,
    FxHealthCheckerTestHarness,
    FxLiquidationEngineTestHarness
} from "./FxPerpSafetySprint1.t.sol";

contract MockLiquidationEngine {
    MockERC20 public immutable rewardToken;

    mapping(bytes32 marketId => mapping(address trader => uint256 timestamp)) public flaggedAt;
    mapping(bytes32 marketId => mapping(address trader => bool)) public isHealthy;
    mapping(bytes32 marketId => mapping(address trader => bool)) public isPartial;
    uint256 public flagCalls;
    uint256 public liquidateCalls;
    uint256 public reward = 10e6;
    int256 public socializedLoss = 3e6;
    uint256 public partialReward = 5e6;
    int256 public partialSocializedLoss = 1e6;

    event AccountFlagged(bytes32 indexed marketId, address indexed trader, address indexed caller);
    event Liquidated(bytes32 indexed marketId, address indexed trader, address indexed caller, uint256 maxClose);

    error AccountHealthy(bytes32 marketId, address trader);

    constructor(MockERC20 rewardToken_) {
        rewardToken = rewardToken_;
    }

    function setHealthy(bytes32 marketId, address trader, bool healthy) external {
        isHealthy[marketId][trader] = healthy;
    }

    function setPartial(bytes32 marketId, address trader, bool isPartial_) external {
        isPartial[marketId][trader] = isPartial_;
    }

    function setReward(uint256 reward_) external {
        reward = reward_;
    }

    function flagAccount(bytes32 marketId, address trader) external {
        if (isHealthy[marketId][trader]) revert AccountHealthy(marketId, trader);
        flaggedAt[marketId][trader] = block.timestamp == 0 ? 1 : block.timestamp;
        ++flagCalls;
        emit AccountFlagged(marketId, trader, msg.sender);
    }

    function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        returns (uint256 liquidatorReward, int256 returnedSocializedLoss)
    {
        require(flaggedAt[marketId][trader] != 0, "not flagged");
        delete flaggedAt[marketId][trader];
        ++liquidateCalls;

        if (isPartial[marketId][trader]) {
            rewardToken.transfer(msg.sender, partialReward);
            emit Liquidated(marketId, trader, msg.sender, maxSizeToCloseAbsE18);
            return (partialReward, partialSocializedLoss);
        }

        rewardToken.transfer(msg.sender, reward);
        emit Liquidated(marketId, trader, msg.sender, maxSizeToCloseAbsE18);
        return (reward, socializedLoss);
    }
}

contract LiquidationRouterHarness is LiquidationRouter {
    constructor(address engine, address rewardToken) LiquidationRouter(engine, rewardToken) {}

    function _engineCall(bytes memory callData) internal override returns (bytes memory result) {
        (bool ok, bytes memory ret) = address(engine).call(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

contract LiquidationRouterTest is Test {
    MockERC20 internal usdc;
    MockLiquidationEngine internal engine;
    LiquidationRouterHarness internal router;

    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");
    address internal constant TRADER = address(0xA11CE);
    address internal constant KEEPER = address(0xB0B);
    address internal constant REWARD_RECIPIENT = address(0xCAFE);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        engine = new MockLiquidationEngine(usdc);
        router = new LiquidationRouterHarness(address(engine), address(usdc));
        usdc.mint(address(engine), 1_000e6);
    }

    function test_liquidateAtomic_flagsLiquidatesAndForwardsReward() public {
        vm.prank(KEEPER);
        (uint256 reward, int256 socializedLoss, uint256 forwarded) = router.liquidateAtomic(MARKET_ID, TRADER, 10e18);

        assertEq(reward, 10e6);
        assertEq(socializedLoss, 3e6);
        assertEq(forwarded, 10e6);
        assertEq(usdc.balanceOf(KEEPER), 10e6);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(engine.flagCalls(), 1);
        assertEq(engine.liquidateCalls(), 1);
        assertEq(engine.flaggedAt(MARKET_ID, TRADER), 0);
    }

    function test_liquidateAtomicToForwardsRewardToRecipient() public {
        vm.prank(KEEPER);
        (,, uint256 forwarded) = router.liquidateAtomicTo(MARKET_ID, TRADER, 10e18, REWARD_RECIPIENT);

        assertEq(forwarded, 10e6);
        assertEq(usdc.balanceOf(KEEPER), 0);
        assertEq(usdc.balanceOf(REWARD_RECIPIENT), 10e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_liquidateAtomic_doesNotResetExistingFlag() public {
        engine.flagAccount(MARKET_ID, TRADER);
        assertEq(engine.flagCalls(), 1);

        vm.prank(KEEPER);
        router.liquidateAtomic(MARKET_ID, TRADER, 10e18);

        assertEq(engine.flagCalls(), 1, "router skipped fresh flag");
        assertEq(engine.liquidateCalls(), 1);
    }

    function test_liquidateBatchProcessesAllItems() public {
        bytes32[] memory marketIds = new bytes32[](2);
        marketIds[0] = MARKET_ID;
        marketIds[1] = keccak256("FX-PERP:JPYC/USDC");
        address[] memory traders = new address[](2);
        traders[0] = TRADER;
        traders[1] = address(0x1234);
        uint256[] memory maxCloses = new uint256[](2);
        maxCloses[0] = 10e18;
        maxCloses[1] = 20e18;

        vm.prank(KEEPER);
        (uint256[] memory rewards, int256[] memory losses, uint256[] memory forwarded) =
            router.liquidateBatch(marketIds, traders, maxCloses);

        assertEq(rewards.length, 2);
        assertEq(rewards[0], 10e6);
        assertEq(rewards[1], 10e6);
        assertEq(losses[0], 3e6);
        assertEq(forwarded[0], 10e6);
        assertEq(forwarded[1], 10e6);
        assertEq(usdc.balanceOf(KEEPER), 20e6);
        assertEq(engine.flagCalls(), 2);
        assertEq(engine.liquidateCalls(), 2);
    }

    function test_liquidateBatchRejectsLengthMismatch() public {
        bytes32[] memory marketIds = new bytes32[](1);
        address[] memory traders = new address[](2);
        uint256[] memory maxCloses = new uint256[](1);

        vm.expectRevert(LiquidationRouter.LengthMismatch.selector);
        router.liquidateBatch(marketIds, traders, maxCloses);
    }

    function test_liquidateAtomicRejectsZeroInputs() public {
        vm.expectRevert(LiquidationRouter.ZeroAddress.selector);
        router.liquidateAtomic(MARKET_ID, address(0), 10e18);

        vm.expectRevert(LiquidationRouter.ZeroAmount.selector);
        router.liquidateAtomic(MARKET_ID, TRADER, 0);

        vm.expectRevert(LiquidationRouter.ZeroAddress.selector);
        router.liquidateAtomicTo(MARKET_ID, TRADER, 10e18, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          NEW TESTS (B6 gap)
    //////////////////////////////////////////////////////////////*/

    function test_liquidateAtomicRevertsWhenNotFlagged() public {
        // Mark the account as healthy so flagAccount reverts.
        engine.setHealthy(MARKET_ID, TRADER, true);

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MockLiquidationEngine.AccountHealthy.selector, MARKET_ID, TRADER));
        router.liquidateAtomic(MARKET_ID, TRADER, 10e18);

        // Verify no flag or liquidation occurred.
        assertEq(engine.flagCalls(), 0);
        assertEq(engine.liquidateCalls(), 0);
    }

    function test_liquidateAtomicHandlesPartialLiquidation() public {
        // Set account as partially underwater — smaller reward + socialized loss.
        engine.setPartial(MARKET_ID, TRADER, true);

        vm.prank(KEEPER);
        (uint256 reward, int256 socializedLoss, uint256 forwarded) = router.liquidateAtomic(MARKET_ID, TRADER, 5e18);

        assertEq(reward, 5e6, "partial reward should be 5e6");
        assertEq(socializedLoss, 1e6, "partial socialized loss should be 1e6");
        assertEq(forwarded, 5e6, "partial forwarded should be 5e6");
        assertEq(usdc.balanceOf(KEEPER), 5e6);
        assertEq(engine.liquidateCalls(), 1);
    }

    function test_liquidateBatchSkipsHealthyAccounts() public {
        // Set TRADER as healthy, second trader as liquidatable.
        address TRADER2 = address(0x2222);
        engine.setHealthy(MARKET_ID, TRADER, true);

        bytes32[] memory marketIds = new bytes32[](2);
        marketIds[0] = MARKET_ID;
        marketIds[1] = MARKET_ID;
        address[] memory traders = new address[](2);
        traders[0] = TRADER; // healthy — will revert
        traders[1] = TRADER2; // liquidatable
        uint256[] memory maxCloses = new uint256[](2);
        maxCloses[0] = 10e18;
        maxCloses[1] = 10e18;

        // The batch iterates sequentially. The first item (healthy account)
        // will revert inside _liquidateAtomicTo, which bubbles up.
        // This verifies the router does not silently skip the revert.
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MockLiquidationEngine.AccountHealthy.selector, MARKET_ID, TRADER));
        router.liquidateBatch(marketIds, traders, maxCloses);
    }

    function test_rewardForwardingToCustomRecipient() public {
        // Verify USDC actually arrives at the custom recipient, not the keeper.
        address CUSTOM_RECIPIENT = address(0xFACE);

        vm.prank(KEEPER);
        (uint256 reward, int256 socializedLoss, uint256 forwarded) =
            router.liquidateAtomicTo(MARKET_ID, TRADER, 10e18, CUSTOM_RECIPIENT);

        assertEq(reward, 10e6);
        assertEq(socializedLoss, 3e6);
        assertEq(forwarded, 10e6);
        // Reward goes to custom recipient.
        assertEq(usdc.balanceOf(CUSTOM_RECIPIENT), 10e6, "reward should arrive at custom recipient");
        // Keeper and router should have zero.
        assertEq(usdc.balanceOf(KEEPER), 0, "keeper should have zero");
        assertEq(usdc.balanceOf(address(router)), 0, "router should have zero");
    }

    function test_liquidateAtomicEmitsCorrectEvents() public {
        vm.prank(KEEPER);

        // Expect AtomicLiquidation event with correct parameters.
        vm.expectEmit(true, true, true, true);
        emit LiquidationRouter.AtomicLiquidation(
            MARKET_ID,
            TRADER,
            KEEPER,
            KEEPER,
            true, // flaggedInCall = true (not pre-flagged)
            10e6, // liquidatorReward
            3e6, // socializedLoss
            10e6 // rewardForwarded
        );
        router.liquidateAtomic(MARKET_ID, TRADER, 10e18);
    }
}

contract LiquidationRouterRealEngineIntegrationTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockPerpOracle internal oracle;
    FxMarginAccount internal margin;
    FxPerpClearinghouseTestHarness internal clearinghouse;
    FxFundingEngine internal funding;
    FxHealthChecker internal health;
    FxLiquidationEngineTestHarness internal liquidation;
    LiquidationRouterHarness internal router;

    address internal constant ADMIN = address(uint160(uint256(keccak256("liq-router.ADMIN"))));
    address internal constant KEEPER = address(uint160(uint256(keccak256("liq-router.KEEPER"))));
    address internal constant TRADER = address(uint160(uint256(keccak256("liq-router.TRADER"))));
    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");
    uint256 internal constant PRICE_1_10 = 1_100_000_000_000_000_000;

    function setUp() public {
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
        router = new LiquidationRouterHarness(address(liquidation), address(usdc));

        clearinghouse.setFundingEngine(address(funding));
        margin.setFundingSettlementHook(address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(funding));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(liquidation));
        clearinghouse.grantRole(clearinghouse.EXECUTOR_ROLE(), KEEPER);
        clearinghouse.grantRole(clearinghouse.LIQUIDATION_ENGINE_ROLE(), address(liquidation));
        clearinghouse.configureMarket(
            MARKET_ID,
            IFxPerpClearinghouse.MarketConfig({
                baseToken: address(eurc),
                enabled: true,
                initialMarginBps: 500,
                maintenanceMarginBps: 300,
                tradingFeeBps: 5,
                maxLeverageBps: 200_000,
                maxOpenInterestUsd: 1_000_000e6,
                maxSkewUsd: 1_000_000e6
            })
        );
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

    function test_realRouterCannotBypassFreshFlagDelay() public {
        _openUnderwaterPosition();

        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSignature("FlagDelayPending(uint256,uint256)", block.timestamp + 60, block.timestamp)
        );
        router.liquidateAtomic(MARKET_ID, TRADER, 10e18);

        assertEq(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "fresh flag was reverted with the tx");
        assertEq(clearinghouse.position(MARKET_ID, TRADER).sizeE18, 10e18, "position remains open");
    }

    function test_realRouterLiquidatesReadyFlagAndForwardsReward() public {
        _openUnderwaterPosition();

        vm.prank(KEEPER);
        liquidation.flagAccount(MARKET_ID, TRADER);
        uint256 flagTs = liquidation.flaggedAt(MARKET_ID, TRADER);
        vm.warp(flagTs + liquidation.MIN_LIQUIDATION_FLAG_DELAY());

        vm.prank(KEEPER);
        (uint256 reward, int256 socializedLoss, uint256 forwarded) = router.liquidateAtomic(MARKET_ID, TRADER, 10e18);

        assertEq(clearinghouse.position(MARKET_ID, TRADER).sizeE18, 0, "position closed through router");
        assertEq(liquidation.flaggedAt(MARKET_ID, TRADER), 0, "flag cleared");
        assertEq(forwarded, reward, "router forwarded exact reward delta");
        assertEq(usdc.balanceOf(KEEPER), reward, "keeper received liquidation reward");
        assertEq(usdc.balanceOf(address(router)), 0, "router retains no reward token");
        assertEq(socializedLoss, 0, "margin covered the close");
    }

    function _openUnderwaterPosition() internal {
        _deposit(TRADER, 2_200_000);
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, 6_000);
        oracle.setMid(address(eurc), address(usdc), 0.9e18);
        assertTrue(health.isLiquidatable(MARKET_ID, TRADER), "position is underwater");
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
