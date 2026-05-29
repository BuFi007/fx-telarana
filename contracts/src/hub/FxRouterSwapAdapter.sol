// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IFxRouterSwapAdapter} from "./FxRouter.sol";

/// @title  FxRouterSwapAdapter
/// @notice Production `IFxRouterSwapAdapter` (the "PR-6" wrapper): executes a
///         cross-currency exact-input swap through a vault-backed `FxSwapHook`
///         Uniswap v4 pool via `PoolManager.unlock`. Drop-in replacement for
///         `FxFixedRateSwapAdapter` — same interface; the owner re-points
///         `FxRouter.setSwapAdapter(this)` and crosses route through real PMM
///         liquidity instead of a fixed rate table.
///
/// ## Flow (FxSwapHook custom-accounting ordering)
///
/// `FxRouter` `safeTransfer`s `sellAmountNet` of `sellToken` to THIS adapter,
/// then calls `swapExactInput`. The adapter is therefore the payer: it settles
/// its own balance into the PoolManager BEFORE `swap` (FxSwapHook takes the
/// specified input during `beforeSwap` and funds the output from the vault via
/// `beforeSwapReturnDelta`), then `take`s the output straight to `recipient`.
/// Exact-input only (`amountSpecified < 0`), mirroring `FxSwapHook.quoteExactInput`.
///
/// ## Composition only (CLAUDE.md constitutional rule)
///
/// No AMM/oracle/fee math here. Pricing + the curve live in `FxSwapHook` +
/// `SharedFxVault`. This adapter orchestrates the v4 unlock/settle/take dance
/// and resolves which pool a (sellToken, buyToken) pair maps to.
///
/// ## Trust + safety
///
/// * `authorizedCaller` gate: only the Router/entrypoint may call. The adapter
///   holds no standing inventory (every swap settles its full input into the
///   pool and takes the output to `recipient`), but the gate prevents an
///   attacker from swapping any dust accidentally sent here. Mirrors the
///   `FxFixedRateSwapAdapter` caller-gate (Codex round-11 HIGH).
/// * `minBuyAmount` enforced inside the callback — under-delivery reverts the
///   whole tx, so the Router's own post-check is belt-and-suspenders.
/// * `ReentrancyGuardTransient` on `swapExactInput`; the PoolManager lock is
///   the canonical guard during the callback.
/// * Owner is `Ownable2Step` (two-step, so a typo cannot brick route admin).
contract FxRouterSwapAdapter is IFxRouterSwapAdapter, IUnlockCallback, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The Uniswap v4 PoolManager this adapter unlocks against.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Directional pool route for a (sellToken, buyToken) pair. The
    ///         PoolKey carries the sorted currencies + fee/tickSpacing/hook;
    ///         swap direction is derived from which currency equals sellToken.
    struct Route {
        PoolKey key;
        bool enabled;
    }

    /// @dev directional: route[sell][buy]. Allowing (A,B) does NOT allow (B,A);
    ///      the owner sets both directions (they resolve to the same PoolKey,
    ///      opposite zeroForOne).
    mapping(address sellToken => mapping(address buyToken => Route)) private _routes;

    /// @notice Callers permitted to invoke `swapExactInput` (the FxRouter /
    ///         FxPrivacyEntrypoint). See contract-level trust note.
    mapping(address caller => bool authorized) public authorizedCaller;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error NotPoolManager(address caller);
    error NotAuthorizedCaller(address caller);
    error RouteDisabled(address sellToken, address buyToken);
    error RouteTokenMismatch();
    error SellEqualsBuy();
    error ZeroSellAmount();
    error AmountTooLarge(uint256 amount);
    error NonPositiveOutput(int128 outputDelta);
    error UnderMinBuy(uint256 buyAmount, uint256 minBuyAmount);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RouteSet(address indexed sellToken, address indexed buyToken, PoolKey key, bool enabled);
    event AuthorizedCallerSet(address indexed caller, bool authorized);
    event Swapped(
        address indexed sellToken,
        address indexed buyToken,
        address indexed recipient,
        uint256 sellAmount,
        uint256 buyAmount
    );

    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        POOL_MANAGER = poolManager_;
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Register/replace the v4 pool that backs a directional pair.
    /// @dev    The key's currencies must be exactly {sellToken, buyToken}
    ///         (sorted by the v4 invariant currency0 < currency1). The swap
    ///         direction is derived at swap time, so a single PoolKey serves
    ///         both directions — call once per direction to enable each.
    function setRoute(address sellToken, address buyToken, PoolKey calldata key, bool enabled)
        external
        onlyOwner
    {
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (sellToken == buyToken) revert SellEqualsBuy();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        // The key must describe exactly this pair (order-agnostic).
        bool matches = (c0 == sellToken && c1 == buyToken) || (c0 == buyToken && c1 == sellToken);
        if (!matches) revert RouteTokenMismatch();
        _routes[sellToken][buyToken] = Route({key: key, enabled: enabled});
        emit RouteSet(sellToken, buyToken, key, enabled);
    }

    /// @notice Authorize / revoke a caller for `swapExactInput`. Expected
    ///         callers: `FxRouter`, `FxPrivacyEntrypoint`. Only authorize
    ///         callers that pre-transfer `sellAmountNet` to this adapter before
    ///         calling (both do) — see the contract-level trust note.
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCaller[caller] = authorized;
        emit AuthorizedCallerSet(caller, authorized);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function routeFor(address sellToken, address buyToken)
        external
        view
        returns (PoolKey memory key, bool enabled)
    {
        Route storage r = _routes[sellToken][buyToken];
        return (r.key, r.enabled);
    }

    /*//////////////////////////////////////////////////////////////
                        IFxRouterSwapAdapter
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFxRouterSwapAdapter
    /// @dev `sellAmountNet` is assumed already delivered to this adapter by the
    ///      authorized caller (Router `safeTransfer`s before calling). The swap
    ///      is exact-input: the entire `sellAmountNet` is consumed by the pool.
    function swapExactInput(
        address sellToken,
        address buyToken,
        uint256 sellAmountNet,
        uint256 minBuyAmount,
        address recipient
    ) external nonReentrant returns (uint256 buyAmount) {
        if (!authorizedCaller[msg.sender]) revert NotAuthorizedCaller(msg.sender);
        if (sellToken == address(0) || buyToken == address(0) || recipient == address(0)) revert ZeroAddress();
        if (sellToken == buyToken) revert SellEqualsBuy();
        if (sellAmountNet == 0) revert ZeroSellAmount();
        if (sellAmountNet > uint256(uint128(type(int128).max))) revert AmountTooLarge(sellAmountNet);

        Route storage r = _routes[sellToken][buyToken];
        if (!r.enabled) revert RouteDisabled(sellToken, buyToken);

        bool zeroForOne = Currency.unwrap(r.key.currency0) == sellToken;

        buyAmount = abi.decode(
            POOL_MANAGER.unlock(abi.encode(r.key, zeroForOne, sellAmountNet, minBuyAmount, recipient)),
            (uint256)
        );

        emit Swapped(sellToken, buyToken, recipient, sellAmountNet, buyAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        v4 UNLOCK CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @dev Settle the adapter's own input into the manager FIRST (FxSwapHook
    ///      takes the specified input during `beforeSwap`), then swap, then take
    ///      the output to `recipient`. Mirrors the proven FxV4RouterHarness path.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager(msg.sender);

        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minBuyAmount, address recipient) =
            abi.decode(rawData, (PoolKey, bool, uint256, uint256, address));

        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;

        // Settle this adapter's own input balance into the PoolManager.
        POOL_MANAGER.sync(input);
        IERC20(Currency.unwrap(input)).safeTransfer(address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();

        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (outputDelta <= 0) revert NonPositiveOutput(outputDelta);

        uint256 amountOut = uint128(outputDelta);
        if (amountOut < minBuyAmount) revert UnderMinBuy(amountOut, minBuyAmount);

        POOL_MANAGER.take(output, recipient, amountOut);
        return abi.encode(amountOut);
    }
}
