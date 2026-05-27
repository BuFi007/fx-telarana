// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquidationRouter} from "../../src/perp/LiquidationRouter.sol";
import {IFxLiquidationEngine} from "../../src/perp/interfaces/IFxLiquidationEngine.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

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
        (uint256 reward, int256 socializedLoss, uint256 forwarded) =
            router.liquidateAtomic(MARKET_ID, TRADER, 10e18);

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
        (uint256 reward, int256 socializedLoss, uint256 forwarded) =
            router.liquidateAtomic(MARKET_ID, TRADER, 5e18);

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
        traders[0] = TRADER;    // healthy — will revert
        traders[1] = TRADER2;   // liquidatable
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
            true,   // flaggedInCall = true (not pre-flagged)
            10e6,   // liquidatorReward
            3e6,    // socializedLoss
            10e6    // rewardForwarded
        );
        router.liquidateAtomic(MARKET_ID, TRADER, 10e18);
    }
}
