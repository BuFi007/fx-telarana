// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FxPerpMath} from "./FxPerpMath.sol";
import {IFxFundingSettlementHook} from "./interfaces/IFxFundingSettlementHook.sol";
import {IFxMarginAccount} from "./interfaces/IFxMarginAccount.sol";

/// @title FxMarginAccount
/// @notice USDC margin custodian for the Phase B-E perp stack.
/// @dev Reference shape:
///      - Synthetix v3 BFP `PerpAccountModule` and `Margin` storage split
///        trader margin from reserved/locked margin.
///      - GMX Synthetics position accounting realizes trader PnL against pool
///        liquidity; this v0.1 stack uses `protocolLiquidity` as the explicit
///        USDC backing bucket until the later LP vault module lands.
contract FxMarginAccount is IFxMarginAccount, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    bytes32 public constant ACCOUNT_OPERATOR_ROLE = keccak256("ACCOUNT_OPERATOR_ROLE");
    bytes32 public constant CLEARINGHOUSE_ROLE = keccak256("CLEARINGHOUSE_ROLE");

    IERC20 public immutable USDC;
    uint8 public immutable MARGIN_DECIMALS;

    mapping(address trader => uint256 amount) private _margin;
    mapping(address trader => uint256 amount) private _reserved;

    uint256 public totalAccountMargin;
    uint256 public protocolLiquidity;
    address public fundingSettlementHook;

    event MarginDeposited(address indexed trader, address indexed payer, uint256 amount);
    event MarginWithdrawn(address indexed trader, uint256 amount);
    event MarginReserved(address indexed trader, uint256 amount);
    event MarginReleased(address indexed trader, uint256 amount);
    event PnlRealized(address indexed trader, int256 pnl, uint256 badDebt);
    event FeeRealized(address indexed trader, address indexed recipient, uint256 amount);
    event ProtocolLiquidityDeposited(address indexed payer, uint256 amount);
    event ProtocolLiquidityWithdrawn(address indexed to, uint256 amount);
    event LiquidatorRewardPaid(address indexed trader, address indexed liquidator, uint256 amount);
    event FundingSettlementHookSet(address indexed hook);

    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedAccount(address caller, address trader);
    error InsufficientFreeMargin(address trader, uint256 requested, uint256 available);
    error InsufficientMargin(address trader, uint256 requested, uint256 available);
    error InsufficientProtocolLiquidity(uint256 requested, uint256 available);
    error InvalidFundingSettlementHook(address hook);

    constructor(address usdc_, address initialAdmin) {
        if (usdc_ == address(0) || initialAdmin == address(0)) revert ZeroAddress();
        USDC = IERC20(usdc_);
        MARGIN_DECIMALS = IERC20Metadata(usdc_).decimals();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
        _grantRole(ACCOUNT_OPERATOR_ROLE, initialAdmin);
    }

    function marginDecimals() external view returns (uint8) {
        return MARGIN_DECIMALS;
    }

    function depositMargin(address trader, uint256 amount) external whenNotPaused nonReentrant {
        if (trader == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _margin[trader] += amount;
        totalAccountMargin += amount;
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit MarginDeposited(trader, msg.sender, amount);
    }

    function setFundingSettlementHook(address hook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hook != address(0) && hook.code.length == 0) revert InvalidFundingSettlementHook(hook);
        fundingSettlementHook = hook;
        emit FundingSettlementHookSet(hook);
    }

    function withdrawMargin(address trader, uint256 amount) external whenNotPaused nonReentrant {
        if (trader == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (msg.sender != trader && !hasRole(ACCOUNT_OPERATOR_ROLE, msg.sender)) {
            revert UnauthorizedAccount(msg.sender, trader);
        }
        _settleFunding(trader);
        uint256 free = freeMarginOf(trader);
        if (amount > free) revert InsufficientFreeMargin(trader, amount, free);
        _margin[trader] -= amount;
        totalAccountMargin -= amount;
        USDC.safeTransfer(trader, amount);
        emit MarginWithdrawn(trader, amount);
    }

    function depositProtocolLiquidity(uint256 amount) external whenNotPaused nonReentrant onlyRole(OPERATIONS_ROLE) {
        if (amount == 0) revert ZeroAmount();
        protocolLiquidity += amount;
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit ProtocolLiquidityDeposited(msg.sender, amount);
    }

    function withdrawProtocolLiquidity(address to, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRole(OPERATIONS_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > protocolLiquidity) revert InsufficientProtocolLiquidity(amount, protocolLiquidity);
        protocolLiquidity -= amount;
        USDC.safeTransfer(to, amount);
        emit ProtocolLiquidityWithdrawn(to, amount);
    }

    function marginOf(address trader) public view returns (uint256) {
        return _margin[trader];
    }

    function reservedMarginOf(address trader) public view returns (uint256) {
        return _reserved[trader];
    }

    function freeMarginOf(address trader) public view returns (uint256) {
        uint256 balance = _margin[trader];
        uint256 locked = _reserved[trader];
        return balance > locked ? balance - locked : 0;
    }

    function reserveMargin(address trader, uint256 amount) external whenNotPaused onlyRole(CLEARINGHOUSE_ROLE) {
        if (trader == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 free = freeMarginOf(trader);
        if (amount > free) revert InsufficientFreeMargin(trader, amount, free);
        _reserved[trader] += amount;
        emit MarginReserved(trader, amount);
    }

    function releaseMargin(address trader, uint256 amount) external whenNotPaused onlyRole(CLEARINGHOUSE_ROLE) {
        if (trader == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 locked = _reserved[trader];
        if (amount > locked) revert InsufficientMargin(trader, amount, locked);
        _reserved[trader] = locked - amount;
        emit MarginReleased(trader, amount);
    }

    function realizePnl(address trader, int256 pnl)
        external
        whenNotPaused
        onlyRole(CLEARINGHOUSE_ROLE)
        returns (uint256 badDebt)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (pnl > 0) {
            uint256 profit = FxPerpMath.abs(pnl);
            if (profit > protocolLiquidity) revert InsufficientProtocolLiquidity(profit, protocolLiquidity);
            protocolLiquidity -= profit;
            _margin[trader] += profit;
            totalAccountMargin += profit;
        } else if (pnl < 0) {
            uint256 loss = FxPerpMath.abs(pnl);
            uint256 available = _margin[trader];
            uint256 paid = loss <= available ? loss : available;
            _margin[trader] = available - paid;
            totalAccountMargin -= paid;
            protocolLiquidity += paid;
            badDebt = loss - paid;
        }
        emit PnlRealized(trader, pnl, badDebt);
    }

    /// @notice Debit trader free margin and pay an explicit fee recipient.
    /// @dev Used by the clearinghouse to route trading fees to TurboFeeVault
    ///      instead of increasing `protocolLiquidity`.
    function realizeFee(address trader, address recipient, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLEARINGHOUSE_ROLE)
        returns (uint256 paid)
    {
        if (trader == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 free = freeMarginOf(trader);
        if (amount > free) revert InsufficientFreeMargin(trader, amount, free);

        _margin[trader] -= amount;
        totalAccountMargin -= amount;
        paid = amount;

        USDC.safeTransfer(recipient, amount);
        emit FeeRealized(trader, recipient, amount);
    }

    function payLiquidatorReward(address trader, address liquidator, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLEARINGHOUSE_ROLE)
    {
        if (trader == address(0) || liquidator == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 available = _margin[trader];
        if (amount > available) revert InsufficientMargin(trader, amount, available);
        _margin[trader] = available - amount;
        totalAccountMargin -= amount;
        USDC.safeTransfer(liquidator, amount);
        emit LiquidatorRewardPaid(trader, liquidator, amount);
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    function _settleFunding(address trader) internal {
        address hook = fundingSettlementHook;
        if (hook == address(0)) return;
        IFxFundingSettlementHook(hook).settleTraderFunding(trader);
    }
}
