// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHedgeTarget} from "../interfaces/IHedgeTarget.sol";
import {IFxPerpClearinghouse} from "../perp/interfaces/IFxPerpClearinghouse.sol";

/// @title  FxHedgeExecutor — P4: on-chain, permissionless IL-hedge execution
/// @notice The IL-shield amplifier of "The Yield Machine" (yield-machine-spec.md). `FxHedgeHook`
///         already computes, on-chain, the perp hedge size that makes each pool delta-neutral
///         (`poolHedgeSizeE18`). Today that target is EXECUTED off-chain by the Rust matcher watching
///         events. This executor moves the trigger ON-CHAIN: a permissionless `executeHedge(poolId)`
///         reads the hook's target + the live clearinghouse position and adjusts the BUFX perp short
///         to match — neutralizing LP impermanent loss so the net LP yield (fees − IL) rises.
///
/// @dev    PERFORMANCE LAW: off the swap hot path by construction. `executeHedge` is a SEPARATE,
///         permissionless tx (the on-chain (s,S)-style poke pattern used by FxReserveYieldRouter) —
///         never called from `beforeSwap`/`afterSwap`. The FX swap path is untouched.
///         COMPLIANCE LAW: moves no USYC; touches only the perp clearinghouse. `retailAssets ∩ USYC`
///         is unaffected (USYC is absent). The hedge raises NET retail LP yield without RWA exposure.
///
///         Execution is synchronous on-chain via IFxPerpClearinghouse.openOrIncrease/decreaseOrClose
///         (no off-chain matcher in the trigger path). A sign-flip converges over two pokes (close to
///         zero, then open the other way) — each poke is idempotent toward the target. The executor is
///         the perp `trader`; it must hold margin in the clearinghouse's margin account (ops funding).
contract FxHedgeExecutor is AccessControl, ReentrancyGuard {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE"); // params

    IHedgeTarget public immutable HEDGE_HOOK; // FxHedgeHook (target source)
    IFxPerpClearinghouse public clearinghouse;

    address public hedgeTrader; // account holding the perp hedge position (margin-funded)
    uint256 public maxFee; // per-adjustment fee cap passed to openOrIncrease
    uint256 public minAdjustE18; // dust threshold — ignore tiny drifts

    mapping(bytes32 poolId => bytes32 marketId) public poolMarket;
    mapping(bytes32 poolId => int256 sizeE18) public executedHedgeE18; // on-chain record (mirrors CH truth)

    error ZeroAddress();
    error PoolMarketNotSet(bytes32 poolId);
    error NoAdjustmentNeeded();

    event PoolMarketSet(bytes32 indexed poolId, bytes32 indexed marketId);
    event ParamsUpdated(address hedgeTrader, uint256 maxFee, uint256 minAdjustE18);
    event ClearinghouseSet(address indexed clearinghouse);
    event HedgeExecuted(bytes32 indexed poolId, bytes32 indexed marketId, int256 target, int256 executed);

    constructor(IHedgeTarget hedgeHook, IFxPerpClearinghouse clearinghouse_, address admin) {
        if (address(hedgeHook) == address(0) || address(clearinghouse_) == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        HEDGE_HOOK = hedgeHook;
        clearinghouse = clearinghouse_;
        hedgeTrader = address(this); // default: the executor holds the hedge position
        maxFee = type(uint256).max;
        minAdjustE18 = 1e15; // 0.001 units of base — ignore dust
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                     PERMISSIONLESS ON-CHAIN HEDGE POKE
    //////////////////////////////////////////////////////////////*/

    /// @notice Adjust the perp hedge for `poolId` toward the hook's on-chain target. Permissionless:
    ///         the target is fixed by the hook, so anyone can keep the hedge in sync. Off the swap path.
    function executeHedge(bytes32 poolId) external nonReentrant returns (int256 executed) {
        bytes32 marketId = poolMarket[poolId];
        if (marketId == bytes32(0)) revert PoolMarketNotSet(poolId);

        int256 target = HEDGE_HOOK.poolHedgeSizeE18(poolId);
        int256 current = clearinghouse.position(marketId, hedgeTrader).sizeE18;
        int256 delta = target - current;
        if (_abs(delta) < minAdjustE18) revert NoAdjustmentNeeded();

        if (current == 0 || _sameSign(current, delta)) {
            // opening from flat, or increasing magnitude in the current direction
            clearinghouse.openOrIncrease(marketId, hedgeTrader, delta, maxFee);
        } else {
            // delta opposes the current position → reduce toward target, clamped so a single call
            // never crosses zero (a sign flip finishes on the next poke)
            int256 reduce = _abs(delta) > _abs(current) ? -current : delta;
            clearinghouse.decreaseOrClose(marketId, hedgeTrader, reduce);
        }

        // Record the clearinghouse truth, not an assumed value.
        executed = clearinghouse.position(marketId, hedgeTrader).sizeE18;
        executedHedgeE18[poolId] = executed;
        emit HedgeExecuted(poolId, marketId, target, executed);
    }

    /// @notice True when the executed hedge already matches the hook target within the dust threshold.
    function isHedged(bytes32 poolId) external view returns (bool) {
        bytes32 marketId = poolMarket[poolId];
        if (marketId == bytes32(0)) return false;
        int256 target = HEDGE_HOOK.poolHedgeSizeE18(poolId);
        int256 current = clearinghouse.position(marketId, hedgeTrader).sizeE18;
        return _abs(target - current) < minAdjustE18;
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/
    function setPoolMarket(bytes32 poolId, bytes32 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        poolMarket[poolId] = marketId;
        emit PoolMarketSet(poolId, marketId);
    }

    function setClearinghouse(IFxPerpClearinghouse clearinghouse_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(clearinghouse_) == address(0)) revert ZeroAddress();
        clearinghouse = clearinghouse_;
        emit ClearinghouseSet(address(clearinghouse_));
    }

    function setParams(address hedgeTrader_, uint256 maxFee_, uint256 minAdjustE18_)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (hedgeTrader_ == address(0)) revert ZeroAddress();
        hedgeTrader = hedgeTrader_;
        maxFee = maxFee_;
        minAdjustE18 = minAdjustE18_;
        emit ParamsUpdated(hedgeTrader_, maxFee_, minAdjustE18_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/
    function _sameSign(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return uint256(v < 0 ? -v : v);
    }
}
