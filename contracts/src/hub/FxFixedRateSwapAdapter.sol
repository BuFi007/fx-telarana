// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFxRouterSwapAdapter} from "./FxRouter.sol";

/// @title FxFixedRateSwapAdapter
/// @notice Owner-operated fixed-rate market maker for the Privacy Hook's
///         cross-currency relay path. Testnet-only — this is the minimal
///         `IFxRouterSwapAdapter` impl that unblocks
///         `FxPrivacyEntrypoint.relayCrossCurrency()` without standing up a
///         full Uniswap V4 + `FxSwapHook` + LP'd pool deployment.
///
///         Semantics: a vending machine. The owner pre-funds the contract
///         with both legs of every supported pair and sets a bidirectional
///         rate. `swapExactInput` reads the rate, computes `buyAmount`,
///         and transfers buy tokens from the contract's own balance to
///         `recipient`. **No AMM curve, no slippage, no LP — just a rate
///         table and a treasury.**
///
///         Production adapter (`FxRouterSwapAdapter` wrapping V4
///         `PoolManager.unlock` + `FxSwapHook` DODO PMM curve) lands as a
///         drop-in replacement: same interface, owner calls
///         `entrypoint.setSwapAdapter(newAdapter)` and crosses are routed
///         through it. The privacy hook itself never changes.
///
/// ## Decimal handling
///
/// Rate is expressed in atomic-unit-per-atomic-unit terms scaled by 1e18.
/// For two 6-decimal stables (USDC, EURC) at 1 USDC = 0.925 EURC, set:
///
///     rate(USDC, EURC) = 0.925e18
///
/// because `buyAmount = sellAmount * rate / 1e18` and both tokens share
/// the same decimal scale. For mixed-decimal pairs, the operator bakes
/// the decimal differential into the rate up-front. The contract makes
/// no decimal assumptions and never reads `IERC20Metadata.decimals()`.
///
/// ## Trust model
///
/// The privacy entrypoint pre-transfers `sellAmount` to this adapter,
/// then calls `swapExactInput`. The adapter is NOT trusted by the
/// entrypoint — the entrypoint measures its own buy-side balance delta
/// after the call and rejects anything under `minBuyAmount`
/// (`AdapterUnderdelivered` revert path in
/// `FxPrivacyEntrypoint.relayCrossCurrency`). So even if a rate or
/// liquidity issue here under-delivers, the entrypoint reverts and the
/// user's withdrawal proof remains unconsumed (the underlying pool's
/// `withdraw` happens in the same tx).
contract FxFixedRateSwapAdapter is IFxRouterSwapAdapter {
    using SafeERC20 for IERC20;

    /// Rate scale factor. `buyAmount = sellAmount * rate / RATE_DENOM`.
    uint256 public constant RATE_DENOM = 1e18;

    /// Owner — sets rates, enables pairs, withdraws stuck liquidity.
    address public owner;

    /// Per-directional rate. `rate[sell][buy] = X` means
    /// `1 atomic sell → X * 1e-18 atomic buy`.
    mapping(address => mapping(address => uint256)) public rate;

    /// Per-directional pair enable. Both `rate > 0` AND `enabled = true`
    /// are required for a swap to succeed.
    mapping(address => mapping(address => bool)) public enabled;

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event RateSet(address indexed sellToken, address indexed buyToken, uint256 rate);
    event PairEnabled(address indexed sellToken, address indexed buyToken, bool enabled);
    event Swapped(
        address indexed sellToken,
        address indexed buyToken,
        address indexed recipient,
        uint256 sellAmount,
        uint256 buyAmount
    );
    event LiquidityWithdrawn(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error ZeroAddress();
    error PairDisabled();
    error SellEqualsBuy();
    error ZeroSellAmount();
    error InsufficientLiquidity(uint256 buyAmount, uint256 available);
    error UnderMinBuy(uint256 buyAmount, uint256 minBuyAmount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnerTransferred(address(0), _owner);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Rotate ownership. Transfer is single-step — caller is
    ///         responsible for not bricking the contract.
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    /// @notice Set the directional rate. Setting to zero implicitly
    ///         disables the pair (the swap path requires `rate > 0`).
    function setRate(address sellToken, address buyToken, uint256 newRate) external onlyOwner {
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (sellToken == buyToken) revert SellEqualsBuy();
        rate[sellToken][buyToken] = newRate;
        emit RateSet(sellToken, buyToken, newRate);
    }

    /// @notice Enable / disable a directional pair without changing its
    ///         rate. Safe pause path — the rate stays warm for re-enable.
    function setEnabled(address sellToken, address buyToken, bool _enabled) external onlyOwner {
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (sellToken == buyToken) revert SellEqualsBuy();
        enabled[sellToken][buyToken] = _enabled;
        emit PairEnabled(sellToken, buyToken, _enabled);
    }

    /// @notice Withdraw idle (or stuck) token balance to `to`. Owner-only.
    ///         Used to rebalance liquidity, sweep dust, or evacuate before
    ///         a planned adapter swap.
    function withdrawLiquidity(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit LiquidityWithdrawn(address(token), to, amount);
        token.safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        IFxRouterSwapAdapter
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFxRouterSwapAdapter
    ///
    /// @dev `sellAmountNet` is assumed to be already in this contract's
    ///      balance (transferred by the caller — `FxPrivacyEntrypoint` does
    ///      `_asset.safeTransfer(adapter, _amountAfterFee)` before calling
    ///      this). We don't pull via transferFrom; that simplifies the
    ///      trust + allowance dance. The adapter assumes the caller
    ///      delivered what it claims.
    function swapExactInput(
        address sellToken,
        address buyToken,
        uint256 sellAmountNet,
        uint256 minBuyAmount,
        address recipient
    ) external returns (uint256 buyAmount) {
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (sellToken == buyToken) revert SellEqualsBuy();
        if (sellAmountNet == 0) revert ZeroSellAmount();
        if (!enabled[sellToken][buyToken]) revert PairDisabled();

        uint256 _rate = rate[sellToken][buyToken];
        if (_rate == 0) revert PairDisabled();

        buyAmount = (sellAmountNet * _rate) / RATE_DENOM;
        if (buyAmount < minBuyAmount) revert UnderMinBuy(buyAmount, minBuyAmount);

        uint256 available = IERC20(buyToken).balanceOf(address(this));
        if (buyAmount > available) revert InsufficientLiquidity(buyAmount, available);

        IERC20(buyToken).safeTransfer(recipient, buyAmount);
        emit Swapped(sellToken, buyToken, recipient, sellAmountNet, buyAmount);
    }
}
