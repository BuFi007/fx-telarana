// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxHedgeExecutor} from "../../src/hub/FxHedgeExecutor.sol";
import {IHedgeTarget} from "../../src/interfaces/IHedgeTarget.sol";
import {IFxPerpClearinghouse} from "../../src/perp/interfaces/IFxPerpClearinghouse.sol";

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
