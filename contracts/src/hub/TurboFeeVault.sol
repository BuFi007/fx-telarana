// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ITurboFeeVault} from "../interfaces/ITurboFeeVault.sol";

/// @title TurboFeeVault
/// @notice Fee splitter + LP yield distribution for BUFX.
///         50% protocol treasury / 40% LP yield pool / 10% insurance fund.
///
///         Settlement contracts call `depositFee()` after each trade.
///         LPs call `deposit()` to stake USDC and earn the 40% yield share.
///         Yield accrues per-share (Synthetix StakingRewards pattern).
contract TurboFeeVault is ITurboFeeVault, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_DEPOSITOR_ROLE = keccak256("FEE_DEPOSITOR_ROLE");
    bytes32 public constant INSURANCE_ADMIN_ROLE = keccak256("INSURANCE_ADMIN_ROLE");

    IERC20 public immutable USDC;

    // --- Fee split (basis points, immutable) ---
    uint256 public constant PROTOCOL_BPS = 5_000; // 50%
    uint256 public constant LP_BPS = 4_000; // 40%
    uint256 public constant INSURANCE_BPS = 1_000; // 10%
    uint256 private constant BPS = 10_000;

    // --- Destinations ---
    address public protocolTreasury;
    uint256 public insuranceBalance;

    // --- LP staking (Synthetix rewards pattern) ---
    uint256 public totalShares;
    uint256 public totalStaked;
    uint256 public rewardPerShareStored; // scaled by 1e18

    mapping(address => uint256) public shares;
    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(address => uint256) public rewards;

    // --- Stats ---
    uint256 public totalFeesCollected;
    uint256 public totalYieldDistributed;

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientInsurance(uint256 requested, uint256 available);
    error UnsupportedFeeToken(address token);

    constructor(IERC20 _usdc, address _treasury) {
        if (address(_usdc) == address(0) || _treasury == address(0)) revert ZeroAddress();
        USDC = _usdc;
        protocolTreasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ─── Fee Ingress ─────────────────────────────────────────────

    function depositFee(address token, uint256 amount, bytes32 marketId)
        external
        onlyRole(FEE_DEPOSITOR_ROLE)
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (token != address(USDC)) revert UnsupportedFeeToken(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 protocolShare = (amount * PROTOCOL_BPS) / BPS;
        uint256 lpShare = (amount * LP_BPS) / BPS;
        uint256 insuranceShare = amount - protocolShare - lpShare;

        IERC20(token).safeTransfer(protocolTreasury, protocolShare);
        insuranceBalance += insuranceShare;

        if (totalShares > 0) {
            rewardPerShareStored += (lpShare * 1e18) / totalShares;
        } else {
            insuranceBalance += lpShare;
        }

        totalFeesCollected += amount;
        emit FeeDeposited(marketId, token, amount, protocolShare, lpShare, insuranceShare);
    }

    // ─── LP Staking ──────────────────────────────────────────────

    function deposit(uint256 assets) external nonReentrant returns (uint256 newShares) {
        if (assets == 0) revert ZeroAmount();
        _updateReward(msg.sender);

        USDC.safeTransferFrom(msg.sender, address(this), assets);

        newShares = totalShares == 0 ? assets : (assets * totalShares) / totalStaked;
        shares[msg.sender] += newShares;
        totalShares += newShares;
        totalStaked += assets;

        emit Deposited(msg.sender, assets, newShares);
    }

    function withdraw(uint256 sharesToBurn) external nonReentrant returns (uint256 assets) {
        if (sharesToBurn == 0) revert ZeroAmount();
        if (sharesToBurn > shares[msg.sender]) {
            revert InsufficientShares(sharesToBurn, shares[msg.sender]);
        }
        _updateReward(msg.sender);

        assets = (sharesToBurn * totalStaked) / totalShares;
        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalStaked -= assets;

        USDC.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, sharesToBurn, assets);
    }

    function claimYield() external nonReentrant returns (uint256 claimed) {
        _updateReward(msg.sender);
        claimed = rewards[msg.sender];
        if (claimed == 0) revert ZeroAmount();
        rewards[msg.sender] = 0;
        totalYieldDistributed += claimed;

        USDC.safeTransfer(msg.sender, claimed);
        emit YieldClaimed(msg.sender, claimed);
    }

    // ─── Insurance ───────────────────────────────────────────────

    function insurancePayout(bytes32 marketId, uint256 amount, string calldata reason)
        external
        onlyRole(INSURANCE_ADMIN_ROLE)
        nonReentrant
    {
        if (amount > insuranceBalance) revert InsufficientInsurance(amount, insuranceBalance);
        insuranceBalance -= amount;
        USDC.safeTransfer(msg.sender, amount);
        emit InsurancePayout(marketId, amount, reason);
    }

    // ─── Views ───────────────────────────────────────────────────

    function pendingYield(address user) external view returns (uint256) {
        uint256 perShare = rewardPerShareStored;
        return rewards[user] + (shares[user] * (perShare - userRewardPerSharePaid[user])) / 1e18;
    }

    function totalDeposits() external view returns (uint256) {
        return totalStaked;
    }

    // ─── Admin ───────────────────────────────────────────────────

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        protocolTreasury = newTreasury;
    }

    // ─── Internal ────────────────────────────────────────────────

    function _updateReward(address user) internal {
        uint256 perShare = rewardPerShareStored;
        uint256 owed = (shares[user] * (perShare - userRewardPerSharePaid[user])) / 1e18;
        rewards[user] += owed;
        userRewardPerSharePaid[user] = perShare;
    }
}
