// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ProxyConnector} from "@redstone-finance/evm-connector/core/ProxyConnector.sol";

import {IFxHealthChecker} from "./interfaces/IFxHealthChecker.sol";
import {IFxLiquidationEngine} from "./interfaces/IFxLiquidationEngine.sol";
import {IFxMarginAccount} from "./interfaces/IFxMarginAccount.sol";
import {IFxPerpClearinghouse} from "./interfaces/IFxPerpClearinghouse.sol";

/// @title FxLiquidationEngine
/// @notice Synthetix-style flag then liquidate flow for unhealthy perp accounts.
/// @dev References:
///      - Synthetix v3 BFP `LiquidationModule.flagPosition` / `liquidatePosition`.
///      - GMX Synthetics `LiquidationUtils` keeper-reward cap pattern.
contract FxLiquidationEngine is IFxLiquidationEngine, AccessControl, Pausable, ReentrancyGuard, ProxyConnector {
    using Math for uint256;
    using SafeCast for uint256;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    uint256 public constant MIN_LIQUIDATION_FLAG_DELAY = 60;

    struct LiquidationConfig {
        uint16 bountyBps;
        uint256 bountyCap;
        uint256 flagDelay;
    }

    IFxHealthChecker public immutable HEALTH;
    IFxPerpClearinghouse public immutable CLEARINGHOUSE;
    IFxMarginAccount public immutable MARGIN;

    LiquidationConfig public liquidationConfig;
    mapping(bytes32 marketId => mapping(address trader => uint256 flaggedAt)) public flaggedAt;

    event LiquidationConfigured(LiquidationConfig config);
    event AccountFlagged(bytes32 indexed marketId, address indexed trader, address indexed flagger);
    /// @notice Emitted whenever a flag is cleared without liquidation.
    /// `auto = true` means the flag was cleared inside `liquidate()`
    /// because the position recovered (codex contract review P1 #5
    /// auto-rescind). `auto = false` means a third party called
    /// `rescindFlag(...)` directly.
    event AccountFlagRescinded(bytes32 indexed marketId, address indexed trader, address indexed caller, bool auto_);
    event AccountLiquidated(
        bytes32 indexed marketId,
        address indexed trader,
        address indexed liquidator,
        uint256 reward,
        int256 socializedLoss
    );

    error ZeroAddress();
    error ZeroAmount();
    error InvalidConfig();
    error AccountHealthy(bytes32 marketId, address trader);
    error AccountStillLiquidatable(bytes32 marketId, address trader);
    error AccountNotFlagged(bytes32 marketId, address trader);
    error FlagDelayPending(uint256 readyAt, uint256 nowTs);
    error Int256Overflow();
    error UnsafeLiquidationFlagDelay(uint256 delay, uint256 minimum);

    constructor(address health_, address clearinghouse_, address marginAccount_, address initialAdmin) {
        if (
            health_ == address(0) || clearinghouse_ == address(0) || marginAccount_ == address(0)
                || initialAdmin == address(0)
        ) {
            revert ZeroAddress();
        }
        HEALTH = IFxHealthChecker(health_);
        CLEARINGHOUSE = IFxPerpClearinghouse(clearinghouse_);
        MARGIN = IFxMarginAccount(marginAccount_);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
    }

    function configureLiquidation(LiquidationConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (config.bountyBps > 5_000) revert InvalidConfig();
        if (config.flagDelay < MIN_LIQUIDATION_FLAG_DELAY) {
            revert UnsafeLiquidationFlagDelay(config.flagDelay, MIN_LIQUIDATION_FLAG_DELAY);
        }
        liquidationConfig = config;
        emit LiquidationConfigured(config);
    }

    function flagAccount(bytes32 marketId, address trader) external whenNotPaused {
        if (trader == address(0)) revert ZeroAddress();
        // Codex contract review P1 #1: gate the flag through the strict
        // deviation-gated oracle path so a Pyth flicker (while RedStone
        // disagrees) can't pre-arm a flag against a healthy account.
        // Caller (flagger) MUST wrap the tx with the RedStone SDK so the
        // signed price payload lands in calldata tail.
        // Sprint-1 round 1 HIGH: the call below MUST forward that payload
        // through THIS contract's `proxyCalldataView` hook so it reaches
        // FxOracle three hops away — a plain Solidity external call
        // would strip the calldata tail.
        if (!_healthIsLiquidatableVerified(marketId, trader)) revert AccountHealthy(marketId, trader);
        flaggedAt[marketId][trader] = block.timestamp;
        emit AccountFlagged(marketId, trader, msg.sender);
    }

    /// @notice Clear a flag against `trader` if the position is currently
    ///         healthy under the strict-oracle health check. Callable by
    ///         anyone — anti-grief surface against the flag-bomb attack
    ///         (codex contract review P1 #5):
    ///
    ///         1. Attacker calls flagAccount during a transient dip.
    ///         2. Price recovers; victim is healthy again; flag persists.
    ///         3. flagDelay elapses.
    ///         4. Price dips a second time; attacker calls liquidate with
    ///            zero second delay.
    ///
    ///         With this surface, anyone (the victim, a friendly keeper,
    ///         the protocol) can clear the stale flag the moment health
    ///         recovers, so step 4 requires a fresh flag + delay.
    function rescindFlag(bytes32 marketId, address trader) external whenNotPaused {
        if (flaggedAt[marketId][trader] == 0) revert AccountNotFlagged(marketId, trader);
        if (_healthIsLiquidatableVerified(marketId, trader)) {
            revert AccountStillLiquidatable(marketId, trader);
        }
        delete flaggedAt[marketId][trader];
        emit AccountFlagRescinded(marketId, trader, msg.sender, false);
    }

    function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 liquidatorReward, int256 socializedLoss)
    {
        if (maxSizeToCloseAbsE18 == 0) revert ZeroAmount();
        // Codex contract review P1 #5 (auto-rescind): if the position
        // recovered between flag and trigger, clear the flag here
        // instead of letting it persist into a future dip. Belt and
        // braces with `rescindFlag` — the public path catches recovery
        // before the delay elapses; this catches recovery after the
        // delay elapses, where a liquidator's revert would otherwise
        // leave the flag spendable on the next dip.
        //
        // The auto-rescind branch returns early (no revert) so the
        // storage write persists across the call. Reverting here would
        // unwind the `delete` and leave the flag spendable, which is
        // exactly the bug we're fixing. The keeper gets zero reward —
        // they wasted gas trying to liquidate a healthy account.
        if (!_healthIsLiquidatableVerified(marketId, trader)) {
            if (flaggedAt[marketId][trader] != 0) {
                delete flaggedAt[marketId][trader];
                emit AccountFlagRescinded(marketId, trader, msg.sender, true);
                return (0, 0);
            }
            revert AccountHealthy(marketId, trader);
        }
        uint256 flagTs = flaggedAt[marketId][trader];
        if (flagTs == 0) revert AccountNotFlagged(marketId, trader);
        uint256 readyAt = flagTs + liquidationConfig.flagDelay;
        if (block.timestamp < readyAt) revert FlagDelayPending(readyAt, block.timestamp);

        (,, uint256 badDebt) = _clearinghouseLiquidatePosition(marketId, trader, maxSizeToCloseAbsE18);
        delete flaggedAt[marketId][trader];

        uint256 remainingMargin = MARGIN.marginOf(trader);
        liquidatorReward = remainingMargin.mulDiv(liquidationConfig.bountyBps, 10_000);
        if (liquidatorReward > liquidationConfig.bountyCap) liquidatorReward = liquidationConfig.bountyCap;
        if (liquidatorReward != 0) MARGIN.payLiquidatorReward(trader, msg.sender, liquidatorReward);

        if (badDebt > uint256(type(int256).max)) revert Int256Overflow();
        socializedLoss = badDebt.toInt256();
        emit AccountLiquidated(marketId, trader, msg.sender, liquidatorReward, socializedLoss);
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    /// @dev Codex sprint-1 round 1 HIGH: RedStone payload forwarding.
    ///      `proxyCalldataView` reads the RedStone payload byte size from
    ///      THIS contract's msg.data tail (set by the keeper's outer call)
    ///      and re-appends those bytes onto the encoded sub-call so that
    ///      FxHealthChecker — and the FxPerpClearinghouse / FxOracle calls
    ///      it makes downstream — see the payload at their own msg.data
    ///      tail. Without this hop, RedStone's `getOracleNumericValuesFromTxMsg`
    ///      reverts because the payload is gone.
    ///
    ///      Marked `virtual` so test harnesses can override and call the
    ///      mock health checker directly without constructing a synthetic
    ///      RedStone payload. Same pattern as `FxOracle._redstoneFetch`.
    function _healthIsLiquidatableVerified(bytes32 marketId, address trader)
        internal
        view
        virtual
        returns (bool liquidatable)
    {
        bytes memory ret = proxyCalldataView(
            address(HEALTH), abi.encodeCall(IFxHealthChecker.isLiquidatableVerified, (marketId, trader))
        );
        liquidatable = abi.decode(ret, (bool));
    }

    /// @dev Mirror of {_healthIsLiquidatableVerified} for the state-changing
    ///      clearinghouse liquidation path. Uses `proxyCalldata` (not
    ///      `proxyCalldataView`) because `liquidatePosition` mutates.
    function _clearinghouseLiquidatePosition(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        internal
        virtual
        returns (uint256 marginReleased, int256 pnl, uint256 badDebt)
    {
        bytes memory ret = proxyCalldata(
            address(CLEARINGHOUSE),
            abi.encodeCall(IFxPerpClearinghouse.liquidatePosition, (marketId, trader, maxSizeToCloseAbsE18)),
            false
        );
        (marginReleased, pnl, badDebt) = abi.decode(ret, (uint256, int256, uint256));
    }
}
