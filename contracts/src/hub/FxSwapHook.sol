// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";
import {IFxMarketRegistry} from "../interfaces/IFxMarketRegistry.sol";

/// @title FxSwapHook
/// @notice Uniswap v4 hook for fx-Telarana FX swaps. Oracle-anchored PMM-style
///         curve over USDC <-> EURC, with LP liquidity rehypothecated into
///         Morpho Blue and JIT-borrow when hook reserves are insufficient.
///
/// Phase 2 (this file):
///   * `beforeSwap`         — oracle mid + constant spread; settle from hook reserves
///   * `afterSwap`          — fee accounting hook
///   * `getHookPermissions` — bit-encoded flags for v4 address salt mining
///
/// Phase 2.5 (TODO, marked inline):
///   * DODO PMM curve math (k, B0, Q0 parameters; size-impact slippage)
///   * LP rehypothecation through `FxMarketRegistry`
///   * JIT-borrow path against the right Morpho market on output shortfall
///   * `afterSwap` writes accrued fees back as Morpho supply
///
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │ User submits swap via Universal Router                                  │
/// │     │                                                                   │
/// │     ▼                                                                   │
/// │ PoolManager.swap → FxSwapHook.beforeSwap                                │
/// │     │                                                                   │
/// │     ├─ IFxOracle.getMid(in, out) → midE18                               │
/// │     ├─ amountOut = amountIn * midE18 * (1 - spreadBps) / 1e18           │
/// │     ├─ check hookReserves[out] >= amountOut                             │
/// │     │       ├─ yes → take amountIn / settle amountOut                   │
/// │     │       └─ no  → JIT borrow from FxMarketRegistry (TODO 2.5)        │
/// │     └─ return BeforeSwapDelta to no-op the default x*y=k curve          │
/// │     │                                                                   │
/// │     ▼                                                                   │
/// │ PoolManager applies hook's delta; tx settles                            │
/// └─────────────────────────────────────────────────────────────────────────┘
contract FxSwapHook is IHooks {
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IPoolManager      public immutable POOL_MANAGER;
    IFxOracle         public immutable ORACLE;
    IFxMarketRegistry public immutable REGISTRY;

    address public owner;

    /// @notice Constant spread charged on top of oracle mid, in basis points.
    /// @dev    50 bps = 0.5%. Update via `setSpreadBps`. Phase 2.5 replaces this
    ///         with DODO PMM curve params (k, B0, Q0) for size-impact-aware
    ///         pricing.
    uint16 public spreadBps;

    /// @notice Max acceptable oracle staleness reuses the oracle's own gate via
    ///         `getMid`. Hook adds no additional staleness check.
    uint16 public constant MAX_SPREAD_BPS = 500;          // 5% upper bound
    uint16 public constant DEFAULT_SPREAD_BPS = 30;       // 0.30%

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotPoolManager();
    error NotOwner();
    error ZeroAddress();
    error SpreadOutOfRange(uint16 requested, uint16 maxBps);
    error HookNotEnabled(bytes4 hook);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SpreadSet(uint16 oldBps, uint16 newBps);
    event Swapped(
        address indexed poolManager,
        Currency indexed input,
        Currency indexed output,
        uint256 amountIn,
        uint256 amountOut,
        uint256 midE18
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address poolManager_, address oracle_, address registry_, address owner_) {
        if (poolManager_ == address(0) || oracle_ == address(0) || registry_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        POOL_MANAGER = IPoolManager(poolManager_);
        ORACLE       = IFxOracle(oracle_);
        REGISTRY     = IFxMarketRegistry(registry_);
        owner        = owner_;
        spreadBps    = DEFAULT_SPREAD_BPS;
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setSpreadBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_SPREAD_BPS) revert SpreadOutOfRange(newBps, MAX_SPREAD_BPS);
        emit SpreadSet(spreadBps, newBps);
        spreadBps = newBps;
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Permission bits encoded into the deploy address (mined via HookMiner).
    ///         Address must satisfy `flags == address(hook) & ALL_HOOK_MASK_BITS`.
    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:               false,
            afterInitialize:                false,
            beforeAddLiquidity:             true,   // Phase 2.5: rehypothecation
            afterAddLiquidity:              false,
            beforeRemoveLiquidity:          true,   // Phase 2.5: rehypothecation
            afterRemoveLiquidity:           false,
            beforeSwap:                     true,
            afterSwap:                      true,
            beforeDonate:                   false,
            afterDonate:                    false,
            beforeSwapReturnDelta:          true,
            afterSwapReturnDelta:           false,
            afterAddLiquidityReturnDelta:   false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                                HOOKS
    //////////////////////////////////////////////////////////////*/

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4)
    {
        revert HookNotEnabled(IHooks.beforeInitialize.selector);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4)
    {
        revert HookNotEnabled(IHooks.afterInitialize.selector);
    }

    function beforeAddLiquidity(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata /* params */,
        bytes calldata /* hookData */
    ) external view override onlyPoolManager returns (bytes4) {
        // Phase 2.5: pull LP tokens from sender, supply into FxMarketRegistry
        // for the appropriate market, mint internal LP-share accounting. For
        // now: accept the add and let v4 handle accounting normally.
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterAddLiquidity.selector);
    }

    function beforeRemoveLiquidity(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata /* params */,
        bytes calldata /* hookData */
    ) external view override onlyPoolManager returns (bytes4) {
        // Phase 2.5: withdraw from FxMarketRegistry, return tokens to LP.
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterRemoveLiquidity.selector);
    }

    /// @notice Oracle-anchored swap. Overrides v4's default x*y=k curve via the
    ///         returned `BeforeSwapDelta`, settling at `mid +/- spreadBps`.
    function beforeSwap(
        address /* sender */,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /* hookData */
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        (Currency inputCurrency, Currency outputCurrency) = params.zeroForOne
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);

        // Pyth-only read here is intentional: routing the deviation-gated path
        // (getMidVerified) requires the swap caller to bundle RedStone payload
        // in msg.data. The hook receives a sliced calldata frame from the
        // PoolManager that does not preserve the user's tail, so we use the
        // cheap view here and rely on Pyth's confidence band + staleness gates.
        // Liquidations + borrow flows MUST use getMidVerified — not swaps.
        (uint256 midE18, ) = ORACLE.getMid(
            Currency.unwrap(inputCurrency),
            Currency.unwrap(outputCurrency)
        );

        // amountSpecified < 0 → exactInput; > 0 → exactOutput.
        // For MVP we support exactInput only; exactOutput reverts (Phase 2.5).
        if (params.amountSpecified > 0) {
            revert HookNotEnabled(IHooks.beforeSwap.selector); // exactOutput TODO
        }
        uint256 amountIn = uint256(-params.amountSpecified);

        // amountOut = amountIn * mid * (1 - spread)
        // mid is base/quote scaled 1e18. For (USDC, EURC) where both are 6 decimals,
        // the unit cancels cleanly. For 18-decimal tokens additional decimal scaling
        // would be needed; we leave that for the multi-asset Phase 3.
        uint256 amountOut = (amountIn * midE18 * (10_000 - spreadBps)) / 1e18 / 10_000;

        // Phase 2.5: if hookReserves[output] < amountOut, JIT-borrow the
        // shortfall from FxMarketRegistry using amountIn as collateral.
        // For now we revert with insufficient inventory — callers cannot
        // exceed the hook's internal balance until JIT lands.

        // Take input from PoolManager, settle output. CurrencySettler handles
        // the sync/transfer/settle dance for ERC-20s.
        inputCurrency.take(POOL_MANAGER, address(this), amountIn, false);
        outputCurrency.settle(POOL_MANAGER, address(this), amountOut, false);

        // BeforeSwapDelta: tells PoolManager that the hook absorbed the user's
        // input (positive delta in input ccy) and returned output (negative
        // delta in output ccy). This zeroes out the default AMM accounting.
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(amountIn)),    // hook owes specified currency to pool (input we took)
            -int128(int256(amountOut))   // hook receives unspecified currency from pool (we paid out)
        );

        emit Swapped(
            msg.sender,
            inputCurrency,
            outputCurrency,
            amountIn,
            amountOut,
            midE18
        );

        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    function afterSwap(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.SwapParams calldata /* params */,
        BalanceDelta /* delta */,
        bytes calldata /* hookData */
    ) external view override onlyPoolManager returns (bytes4, int128) {
        // Phase 2.5: aggregate accrued fees and push them back into the
        // FxMarketRegistry supply position so LPs earn supply APY on top of
        // swap fees (the Bunni rehypothecation pattern).
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        revert HookNotEnabled(IHooks.beforeDonate.selector);
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        revert HookNotEnabled(IHooks.afterDonate.selector);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN ESCAPE
    //////////////////////////////////////////////////////////////*/

    /// @notice Sweep any token sitting at the hook (e.g., dust). Owner-only.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
