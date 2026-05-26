// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquidationRouter} from "../../src/perp/LiquidationRouter.sol";
import {IFxLiquidationEngine} from "../../src/perp/interfaces/IFxLiquidationEngine.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MockLiquidationEngine {
    MockERC20 public immutable rewardToken;

    mapping(bytes32 marketId => mapping(address trader => uint256 timestamp)) public flaggedAt;
    uint256 public flagCalls;
    uint256 public liquidateCalls;
    uint256 public reward = 10e6;
    int256 public socializedLoss = 3e6;

    event AccountFlagged(bytes32 indexed marketId, address indexed trader, address indexed caller);
    event Liquidated(bytes32 indexed marketId, address indexed trader, address indexed caller, uint256 maxClose);

    constructor(MockERC20 rewardToken_) {
        rewardToken = rewardToken_;
    }

    function flagAccount(bytes32 marketId, address trader) external {
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
}
