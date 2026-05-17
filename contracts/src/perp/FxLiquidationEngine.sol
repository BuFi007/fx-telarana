// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFxHealthChecker} from "./interfaces/IFxHealthChecker.sol";
import {IFxLiquidationEngine} from "./interfaces/IFxLiquidationEngine.sol";
import {IFxMarginAccount} from "./interfaces/IFxMarginAccount.sol";
import {IFxPerpClearinghouse} from "./interfaces/IFxPerpClearinghouse.sol";

/// @title FxLiquidationEngine
/// @notice Synthetix-style flag then liquidate flow for unhealthy perp accounts.
/// @dev References:
///      - Synthetix v3 BFP `LiquidationModule.flagPosition` / `liquidatePosition`.
///      - GMX Synthetics `LiquidationUtils` keeper-reward cap pattern.
contract FxLiquidationEngine is IFxLiquidationEngine, AccessControl, Pausable, ReentrancyGuard {
    using Math for uint256;
    using SafeCast for uint256;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");

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
    error AccountNotFlagged(bytes32 marketId, address trader);
    error FlagDelayPending(uint256 readyAt, uint256 nowTs);
    error Int256Overflow();

    constructor(address health_, address clearinghouse_, address marginAccount_, address initialAdmin) {
        if (health_ == address(0) || clearinghouse_ == address(0) || marginAccount_ == address(0) || initialAdmin == address(0)) {
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
        liquidationConfig = config;
        emit LiquidationConfigured(config);
    }

    function flagAccount(bytes32 marketId, address trader) external whenNotPaused {
        if (trader == address(0)) revert ZeroAddress();
        if (!HEALTH.isLiquidatable(marketId, trader)) revert AccountHealthy(marketId, trader);
        flaggedAt[marketId][trader] = block.timestamp;
        emit AccountFlagged(marketId, trader, msg.sender);
    }

    function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 liquidatorReward, int256 socializedLoss)
    {
        if (maxSizeToCloseAbsE18 == 0) revert ZeroAmount();
        if (!HEALTH.isLiquidatable(marketId, trader)) revert AccountHealthy(marketId, trader);
        uint256 flagTs = flaggedAt[marketId][trader];
        if (flagTs == 0) revert AccountNotFlagged(marketId, trader);
        uint256 readyAt = flagTs + liquidationConfig.flagDelay;
        if (block.timestamp < readyAt) revert FlagDelayPending(readyAt, block.timestamp);

        (,, uint256 badDebt) = CLEARINGHOUSE.liquidatePosition(marketId, trader, maxSizeToCloseAbsE18);
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
}
