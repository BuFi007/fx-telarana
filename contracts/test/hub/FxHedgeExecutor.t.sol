// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxHedgeExecutor} from "../../src/hub/FxHedgeExecutor.sol";
import {FxHedgeHook} from "../../src/hub/FxHedgeHook.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {IHedgeTarget} from "../../src/interfaces/IHedgeTarget.sol";
import {FxFundingEngine} from "../../src/perp/FxFundingEngine.sol";
import {FxMarginAccount} from "../../src/perp/FxMarginAccount.sol";
import {IFxPerpClearinghouse} from "../../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPerpOracle} from "../perp/FxPerpStack.t.sol";
import {FxPerpClearinghouseTestHarness} from "../perp/FxPerpSafetySprint1.t.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Settable hedge-target source (FxHedgeHook satisfies IHedgeTarget via its public mapping).
contract MockHedgeTarget is IHedgeTarget {
    mapping(bytes32 => int256) internal _t;

    function setTarget(bytes32 poolId, int256 target) external {
        _t[poolId] = target;
    }

    function poolHedgeSizeE18(bytes32 poolId) external view returns (int256) {
        return _t[poolId];
    }
}

/// @dev Faithful perp clearinghouse stand-in (the perp-execution boundary — a real interface, the
///      FxPerpClearinghouse implements these exact signatures; NOT a Morpho mock). Tracks the signed
///      position and applies signed deltas; margin/funding/fees are out of scope for the executor's
///      trigger logic and are stubbed.
contract MockPerpClearinghouse is IFxPerpClearinghouse {
    mapping(bytes32 => mapping(address => Position)) internal _pos;

    function openOrIncrease(bytes32 m, address t, int256 sizeDeltaE18, uint256) external returns (bytes32) {
        _pos[m][t].sizeE18 += sizeDeltaE18;
        return bytes32(0);
    }

    function decreaseOrClose(bytes32 m, address t, int256 sizeDeltaE18) external returns (uint256) {
        _pos[m][t].sizeE18 += sizeDeltaE18;
        return 0;
    }

    function position(bytes32 m, address t) external view returns (Position memory) {
        return _pos[m][t];
    }

    // --- unused-by-executor stubs ---
    function applyOrderFill(bytes32, address, int256, uint256, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function liquidatePosition(bytes32, address, uint256) external pure returns (uint256, int256, uint256) {
        return (0, 0, 0);
    }

    function quoteFee(bytes32, address, int256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function unrealizedPnl(bytes32, address) external pure returns (int256) {
        return 0;
    }

    function unrealizedPnlVerified(bytes32, address) external pure returns (int256) {
        return 0;
    }

    function marketConfig(bytes32) external pure returns (MarketConfig memory c) {
        return c;
    }

    function openInterestLong(bytes32) external pure returns (uint256) {
        return 0;
    }

    function openInterestShort(bytes32) external pure returns (uint256) {
        return 0;
    }

    function maxOpenInterest(bytes32) external pure returns (uint256) {
        return 0;
    }

    function marginAccount() external pure returns (address) {
        return address(0);
    }

    function fundingEngine() external pure returns (address) {
        return address(0);
    }

    function settleTraderFunding(address) external pure returns (int256) {
        return 0;
    }
}

contract FxHedgeExecutorTest is Test {
    MockHedgeTarget hook;
    MockPerpClearinghouse ch;
    FxHedgeExecutor exec;

    address admin = address(this);
    bytes32 constant POOL = keccak256("cirBTC/USDC");
    bytes32 constant MARKET = keccak256("cirBTC-USD");

    function setUp() public {
        hook = new MockHedgeTarget();
        ch = new MockPerpClearinghouse();
        exec = new FxHedgeExecutor(IHedgeTarget(address(hook)), IFxPerpClearinghouse(address(ch)), admin);
        exec.setPoolMarket(POOL, MARKET);
    }

    function _size() internal view returns (int256) {
        return ch.position(MARKET, address(exec)).sizeE18;
    }

    /*//////////////////////////////////////////////////////////////
                         OPEN / INCREASE / REDUCE
    //////////////////////////////////////////////////////////////*/

    function test_p4_opensShortToTarget() public {
        hook.setTarget(POOL, -100e18); // pool long-BTC exposure ⇒ short hedge
        exec.executeHedge(POOL);
        assertEq(_size(), -100e18, "perp short opened to target");
        assertEq(exec.executedHedgeE18(POOL), -100e18, "executed hedge recorded on-chain");
    }

    function test_p4_increasesShort() public {
        hook.setTarget(POOL, -100e18);
        exec.executeHedge(POOL);
        hook.setTarget(POOL, -150e18);
        exec.executeHedge(POOL);
        assertEq(_size(), -150e18, "short increased to new target");
    }

    function test_p4_reducesShort() public {
        hook.setTarget(POOL, -150e18);
        exec.executeHedge(POOL);
        hook.setTarget(POOL, -50e18);
        exec.executeHedge(POOL);
        assertEq(_size(), -50e18, "short reduced toward target");
    }

    /// @dev A sign flip (short → long hedge) converges over two permissionless pokes: close to zero,
    ///      then open the other way — never crossing zero in one call.
    function test_p4_signFlipConvergesInTwoPokes() public {
        hook.setTarget(POOL, -50e18);
        exec.executeHedge(POOL); // short 50

        hook.setTarget(POOL, 30e18); // now want long hedge 30
        exec.executeHedge(POOL); // poke 1 → clamp to zero
        assertEq(_size(), 0, "first poke closes to zero, no zero-cross");

        exec.executeHedge(POOL); // poke 2 → open the other way
        assertEq(_size(), 30e18, "second poke reaches the flipped target");
    }

    /*//////////////////////////////////////////////////////////////
                          GUARDS / NO-OP
    //////////////////////////////////////////////////////////////*/

    function test_p4_noAdjustmentAtTarget() public {
        hook.setTarget(POOL, -100e18);
        exec.executeHedge(POOL);
        vm.expectRevert(FxHedgeExecutor.NoAdjustmentNeeded.selector);
        exec.executeHedge(POOL); // already at target
    }

    function test_p4_dustDriftIgnored() public {
        hook.setTarget(POOL, -100e18);
        exec.executeHedge(POOL);
        hook.setTarget(POOL, -100e18 - 1e14); // 1e14 < minAdjust 1e15
        vm.expectRevert(FxHedgeExecutor.NoAdjustmentNeeded.selector);
        exec.executeHedge(POOL);
    }

    function test_p4_requiresPoolMarketConfigured() public {
        bytes32 unknown = keccak256("not-configured");
        hook.setTarget(unknown, -10e18);
        vm.expectRevert(abi.encodeWithSelector(FxHedgeExecutor.PoolMarketNotSet.selector, unknown));
        exec.executeHedge(unknown);
    }

    /*//////////////////////////////////////////////////////////////
                       PERMISSIONLESS + ON-CHAIN RECORD
    //////////////////////////////////////////////////////////////*/

    function test_p4_executeIsPermissionless() public {
        hook.setTarget(POOL, -100e18);
        vm.prank(makeAddr("randomKeeper")); // not admin, not a privileged role
        exec.executeHedge(POOL);
        assertEq(_size(), -100e18, "anyone can keep the hedge in sync");
    }

    function test_p4_isHedgedView() public {
        hook.setTarget(POOL, -100e18);
        assertFalse(exec.isHedged(POOL), "not hedged before execution");
        exec.executeHedge(POOL);
        assertTrue(exec.isHedged(POOL), "hedged after execution");
        hook.setTarget(POOL, -200e18);
        assertFalse(exec.isHedged(POOL), "drift detected when target moves");
    }

    function test_p4_setPoolMarket_onlyAdmin() public {
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert();
        exec.setPoolMarket(POOL, MARKET);
    }
}

contract FxHedgeHookExecutorIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    MockERC20 internal usdc;
    MockERC20 internal jpyc;
    MockPerpOracle internal oracle;
    FxMarginAccount internal margin;
    FxPerpClearinghouseTestHarness internal clearinghouse;
    FxFundingEngine internal funding;
    FxHedgeHook internal hook;
    FxHedgeExecutor internal executor;

    address internal admin = address(this);
    address internal poolManager = address(0xBEEF);
    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:JPYC/USDC");
    bytes32 internal constant PYTH_JPY_USD = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    uint256 internal constant THRESHOLD = 100e18;

    PoolKey internal key;
    bytes32 internal poolId;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        jpyc = new MockERC20("JPYC", "JPYC", 18);
        oracle = new MockPerpOracle();
        oracle.setMid(address(jpyc), address(usdc), 1e18);

        margin = new FxMarginAccount(address(usdc), admin);
        clearinghouse = new FxPerpClearinghouseTestHarness(address(usdc), address(oracle), address(margin), admin);
        funding = new FxFundingEngine(address(clearinghouse), address(margin), admin);
        clearinghouse.setFundingEngine(address(funding));
        margin.setFundingSettlementHook(address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(funding));
        funding.configureFunding(
            MARKET_ID,
            FxFundingEngine.FundingConfig({enabled: true, maxFundingRateBpsPerSecond: 1, fundingVelocityBps: 1_000})
        );
        clearinghouse.configureMarket(
            MARKET_ID,
            IFxPerpClearinghouse.MarketConfig({
                baseToken: address(jpyc),
                enabled: true,
                initialMarginBps: 500,
                maintenanceMarginBps: 300,
                tradingFeeBps: 5,
                maxLeverageBps: 200_000,
                maxOpenInterestUsd: 1_000_000e6,
                maxSkewUsd: 1_000_000e6
            })
        );

        hook = _deployHook();
        key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(jpyc)),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        poolId = PoolId.unwrap(key.toId());
        hook.configurePool(key, MARKET_ID, address(jpyc), 18, PYTH_JPY_USD, THRESHOLD, true);

        executor = new FxHedgeExecutor(IHedgeTarget(address(hook)), IFxPerpClearinghouse(address(clearinghouse)), admin);
        executor.setPoolMarket(poolId, MARKET_ID);
        clearinghouse.grantRole(clearinghouse.EXECUTOR_ROLE(), address(executor));
        _depositMargin(address(executor), 10_000e6);
    }

    function test_hookTargetNeedsExecutorPokeToOpenRealPerpHedge() public {
        vm.prank(poolManager);
        hook.afterAddLiquidity(
            address(this),
            key,
            _modifyParams(1),
            toBalanceDelta(-1_000e6, -2_000e18),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        assertEq(hook.poolExposureE18(poolId), 2_000e18, "pool exposure tracked");
        assertEq(hook.poolHedgeSizeE18(poolId), -2_000e18, "hook target is a short hedge");
        assertEq(clearinghouse.position(MARKET_ID, address(executor)).sizeE18, 0, "hook does not self-execute");
        assertFalse(executor.isHedged(poolId), "executor has not opened the perp yet");

        vm.prank(makeAddr("permissionlessKeeper"));
        executor.executeHedge(poolId);

        assertEq(clearinghouse.position(MARKET_ID, address(executor)).sizeE18, -2_000e18, "perp short opened");
        assertEq(executor.executedHedgeE18(poolId), -2_000e18, "executor records clearinghouse truth");
        assertTrue(executor.isHedged(poolId), "clearinghouse is synced to target");
        assertTrue(hook.isDeltaNeutral(poolId), "hook target neutralizes pool delta");
    }

    function _depositMargin(address trader, uint256 amount) internal {
        usdc.mint(admin, amount);
        usdc.approve(address(margin), amount);
        margin.depositMargin(trader, amount);
    }

    function _deployHook() internal returns (FxHedgeHook deployedHook) {
        bytes memory creationCode =
            abi.encodePacked(type(FxHedgeHook).creationCode, abi.encode(IPoolManager(poolManager), admin, THRESHOLD));
        (address expected,) = HookMiner.find(address(this), _hedgeHookFlags(), creationCode, 500_000);
        deployCodeTo(_fxHedgeHookArtifact(), abi.encode(IPoolManager(poolManager), admin, THRESHOLD), expected);
        deployedHook = FxHedgeHook(expected);
    }

    function _modifyParams(int256 liquidityDelta) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
    }

    function _hedgeHookFlags() internal pure returns (uint160) {
        return uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    }

    function _fxHedgeHookArtifact() internal view returns (string memory) {
        if (vm.isFile("out/FxHedgeHook.sol/FxHedgeHook.json")) return "out/FxHedgeHook.sol/FxHedgeHook.json";
        if (vm.isFile("out/FxHedgeHook.sol/FxHedgeHook.0.8.26.json")) {
            return "out/FxHedgeHook.sol/FxHedgeHook.0.8.26.json";
        }
        if (vm.isFile("out/FxHedgeHook.sol/FxHedgeHook.0.8.28.json")) {
            return "out/FxHedgeHook.sol/FxHedgeHook.0.8.28.json";
        }
        return "";
    }
}
