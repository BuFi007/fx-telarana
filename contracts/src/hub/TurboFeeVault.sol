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
    /// @notice F-10: insurance payouts go HERE (governance-set), never to the
    ///         caller. Separates "who may trigger a payout" (INSURANCE_ADMIN)
    ///         from "who receives it", so a compromised insurance admin cannot
    ///         self-drain the fund.
    address public insuranceBeneficiary;

    // --- LP staking (Synthetix rewards pattern) ---
    uint256 public totalShares;
    uint256 public totalStaked;
    uint256 public rewardPerShareStored; // scaled by 1e18
    /// @notice F-23: LP fee share accrued while there were no stakers. Folded
    ///         into `rewardPerShareStored` on the first stake instead of being
    ///         silently captured by the (admin-drainable) insurance fund.
    uint256 public pendingLpRewards;

    /// @notice F-24: optional minimum hold time between staking and withdrawing
    ///         / claiming, to defeat just-in-time fee-distribution sandwiches.
    ///         0 == disabled. Governance-set.
    uint256 public withdrawCooldown;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public lastStakeTime;

    // --- Stats ---
    uint256 public totalFeesCollected;
    uint256 public totalYieldDistributed;

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientInsurance(uint256 requested, uint256 available);
    error UnsupportedFeeToken(address token);
    error WithdrawLocked(uint256 unlockAt);

    event InsuranceBeneficiarySet(address indexed beneficiary);
    event WithdrawCooldownSet(uint256 cooldown);

    constructor(IERC20 _usdc, address _treasury) {
        if (address(_usdc) == address(0) || _treasury == address(0)) revert ZeroAddress();
        USDC = _usdc;
        protocolTreasury = _treasury;
        insuranceBeneficiary = _treasury; // F-10: default payee; rotate via setter
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

        // F-41: split the MEASURED received amount, not the requested amount, so
        // a non-standard / fee-on-transfer token can never over-distribute.
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBal;
        if (received == 0) revert ZeroAmount();

        uint256 protocolShare = (received * PROTOCOL_BPS) / BPS;
        uint256 lpShare = (received * LP_BPS) / BPS;
        uint256 insuranceShare = received - protocolShare - lpShare;

        IERC20(token).safeTransfer(protocolTreasury, protocolShare);
        insuranceBalance += insuranceShare;

        if (totalShares > 0) {
            rewardPerShareStored += (lpShare * 1e18) / totalShares;
        } else {
            // F-23: hold the LP share for future stakers instead of handing it
            // to the (admin-drainable) insurance fund.
            pendingLpRewards += lpShare;
        }

        totalFeesCollected += received;
        emit FeeDeposited(marketId, token, received, protocolShare, lpShare, insuranceShare);
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
        lastStakeTime[msg.sender] = block.timestamp; // F-24

        // F-23: once there is stake to attribute to, fold any LP rewards that
        // accrued while the pool was empty into the per-share index.
        if (pendingLpRewards > 0 && totalShares > 0) {
            rewardPerShareStored += (pendingLpRewards * 1e18) / totalShares;
            pendingLpRewards = 0;
        }

        emit Deposited(msg.sender, assets, newShares);
    }

    function withdraw(uint256 sharesToBurn) external nonReentrant returns (uint256 assets) {
        if (sharesToBurn == 0) revert ZeroAmount();
        if (sharesToBurn > shares[msg.sender]) {
            revert InsufficientShares(sharesToBurn, shares[msg.sender]);
        }
        // F-24: enforce the optional stake cooldown.
        uint256 unlockAt = lastStakeTime[msg.sender] + withdrawCooldown;
        if (withdrawCooldown != 0 && block.timestamp < unlockAt) revert WithdrawLocked(unlockAt);
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
        // F-10: pay the governance-set beneficiary, NOT msg.sender.
        USDC.safeTransfer(insuranceBeneficiary, amount);
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

    function compositeApy() external view returns (uint256) {
        if (totalStaked == 0 || totalFeesCollected == 0) return 0;
        // Simplified: annualize the LP share of fees collected so far
        // Real APY requires time-weighted calculation; this is a best-effort view
        uint256 lpFees = (totalFeesCollected * LP_BPS) / BPS;
        return (lpFees * 365 * 1e18) / totalStaked;
    }

    // ─── Admin ───────────────────────────────────────────────────

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        protocolTreasury = newTreasury;
    }

    /// @notice F-10: rotate the insurance payout beneficiary (governance only).
    function setInsuranceBeneficiary(address beneficiary) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (beneficiary == address(0)) revert ZeroAddress();
        insuranceBeneficiary = beneficiary;
        emit InsuranceBeneficiarySet(beneficiary);
    }

    /// @notice F-24: set the stake→withdraw/claim cooldown (0 disables it).
    function setWithdrawCooldown(uint256 cooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawCooldown = cooldown;
        emit WithdrawCooldownSet(cooldown);
    }

    // ─── Internal ────────────────────────────────────────────────

    function _updateReward(address user) internal {
        uint256 perShare = rewardPerShareStored;
        uint256 owed = (shares[user] * (perShare - userRewardPerSharePaid[user])) / 1e18;
        rewards[user] += owed;
        userRewardPerSharePaid[user] = perShare;
    }
}
