// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
/// @notice Uniswap v4 hook for fx-Telarana FX swaps. Locked to a single
///         (token0, token1) pair (USDC, EURC at MVP). Oracle-anchored
///         pricing with simplified DODO-style size-impact slippage.
///         Hook-owned LP accounting via `deposit` / `redeem`.
///
/// What ships in Phase 2.5 (this version):
///   * Oracle-anchored quote: amountOut = amountIn * mid * (1 - spread) * (1 - sizeImpact)
///   * Size-impact (linear, k-parameterized): impact = k * amountIn / (reserveIn + amountIn)
///   * Hook-owned LP: deposit pulls token0/token1 from caller, mints shares;
///     redeem burns shares, returns tokens pro-rata of current hook balance.
///     Donations to the hook accrue to LPs (intentional — arb/fee surfaces).
///   * exactInput swaps only (exactOutput Phase 2.6).
///
/// Phase 2.6 (TODO, marked inline):
///   * LP rehypothecation: push deposits into FxMarketRegistry supply, keep
///     a small hot reserve; track Morpho shares per LP.
///   * JIT-borrow on output shortfall using same-pair collateral position.
///   * afterSwap: route accrued fees back into Morpho supply (Bunni pattern).
///   * Full DODO PMM curve math (B0/Q0 targets, regime detection, integral
///     pricing instead of linear approximation).
///
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │ LP path                            Swap path                           │
/// │  deposit(amount0, amount1)          PoolManager.swap                   │
/// │      → mints LP shares                  → beforeSwap                   │
/// │      → tokens held by hook                  → IFxOracle.getMid         │
/// │                                             → _quote(amountIn,         │
/// │  redeem(shares)                                  reserveIn,            │
/// │      → returns share-of-balance                  reserveOut, mid,      │
/// │        of token0 + token1                        spread, k)            │
/// │                                              → take/settle via         │
/// │                                                CurrencySettler        │
/// │                                              → emit Swapped           │
/// └─────────────────────────────────────────────────────────────────────────┘
contract FxSwapHook is IHooks, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IPoolManager      public immutable POOL_MANAGER;
    IFxOracle         public immutable ORACLE;
    IFxMarketRegistry public immutable REGISTRY;

    /// @notice Locked token pair. token0 < token1 by address (v4 convention).
    address public immutable TOKEN0;
    address public immutable TOKEN1;

    address public owner;

    /// @notice Configurable PMM knobs. spread is a constant cost on top of mid.
    ///         k is the size-impact slope: max additional slippage as trade size
    ///         approaches infinity is `k / 10_000` (in bps). 50 = max 0.5%.
    uint16 public spreadBps;
    uint16 public kBps;

    uint16 public constant MAX_SPREAD_BPS = 500;     // 5% upper bound
    uint16 public constant MAX_K_BPS      = 1_000;   // max size-impact slope 10%
    uint16 public constant DEFAULT_SPREAD_BPS = 30;
    uint16 public constant DEFAULT_K_BPS      = 50;

    /*//////////////////////////////////////////////////////////////
                                LP STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Total LP shares outstanding.
    uint256 public totalShares;

    /// @notice LP balance per address. Shares are pure unit-of-account; redeem
    ///         returns share-of-balance pro-rata of current hook holdings.
    mapping(address => uint256) public sharesOf;

    /// @notice Minimum shares burned on first deposit. Bootstrap-attack guard.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotPoolManager();
    error NotOwner();
    error ZeroAddress();
    error SpreadOutOfRange(uint16 requested, uint16 maxBps);
    error KOutOfRange(uint16 requested, uint16 maxBps);
    error HookNotEnabled(bytes4 hook);
    error PoolKeyMismatch();
    error InsufficientLiquidity(uint256 reserveOut, uint256 amountOutRequested);
    error InsufficientShares(uint256 requested, uint256 available);
    error ZeroAmount();
    error TokensNotSorted();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SpreadSet(uint16 oldBps, uint16 newBps);
    event KSet(uint16 oldBps, uint16 newBps);
    event Deposited(address indexed lp, uint256 amount0, uint256 amount1, uint256 sharesMinted);
    event Redeemed(address indexed lp, uint256 shares, uint256 amount0, uint256 amount1);
    event Swapped(
        address indexed sender,
        Currency indexed input,
        Currency indexed output,
        uint256 amountIn,
        uint256 amountOut,
        uint256 midE18,
        uint256 reserveIn,
        uint256 reserveOut
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

    constructor(
        address poolManager_,
        address oracle_,
        address registry_,
        address owner_,
        address token0_,
        address token1_
    ) {
        if (
            poolManager_ == address(0) || oracle_ == address(0) || registry_ == address(0)
                || owner_ == address(0) || token0_ == address(0) || token1_ == address(0)
        ) revert ZeroAddress();
        if (token0_ >= token1_) revert TokensNotSorted();

        POOL_MANAGER = IPoolManager(poolManager_);
        ORACLE       = IFxOracle(oracle_);
        REGISTRY     = IFxMarketRegistry(registry_);
        owner        = owner_;
        TOKEN0       = token0_;
        TOKEN1       = token1_;
        spreadBps    = DEFAULT_SPREAD_BPS;
        kBps         = DEFAULT_K_BPS;
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setSpreadBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_SPREAD_BPS) revert SpreadOutOfRange(newBps, MAX_SPREAD_BPS);
        emit SpreadSet(spreadBps, newBps);
        spreadBps = newBps;
    }

    function setKBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_K_BPS) revert KOutOfRange(newBps, MAX_K_BPS);
        emit KSet(kBps, newBps);
        kBps = newBps;
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                LP API
    //////////////////////////////////////////////////////////////*/

    /// @notice Add liquidity to the hook. Caller transfers `amount0` of TOKEN0
    ///         and `amount1` of TOKEN1; receives `shares` LP units.
    /// @dev    Share math uses current hook balance (`balanceOf(this)`) as the
    ///         total-asset basis, so accumulated swap fees automatically
    ///         appreciate existing LP positions.
    function deposit(uint256 amount0, uint256 amount1)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        uint256 bal0Before = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1Before = IERC20(TOKEN1).balanceOf(address(this));

        if (totalShares == 0) {
            // Bootstrap: shares = sqrt-like measure of the deposit. Using sum
            // since the pair is stable; for volatile pairs `sqrt(a0*a1)` is
            // safer. Burn MINIMUM_LIQUIDITY to first depositor as anti-grief.
            shares = amount0 + amount1;
            if (shares <= MINIMUM_LIQUIDITY) revert ZeroAmount();
            shares -= MINIMUM_LIQUIDITY;
            sharesOf[address(0)] += MINIMUM_LIQUIDITY;
            totalShares += MINIMUM_LIQUIDITY;
        } else {
            // shares = min over assets, so depositor can't dilute themselves
            uint256 s0 = bal0Before == 0 ? type(uint256).max : (amount0 * totalShares) / bal0Before;
            uint256 s1 = bal1Before == 0 ? type(uint256).max : (amount1 * totalShares) / bal1Before;
            shares = s0 < s1 ? s0 : s1;
            if (shares == 0) revert ZeroAmount();
        }

        if (amount0 > 0) IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), amount1);

        sharesOf[msg.sender] += shares;
        totalShares          += shares;

        emit Deposited(msg.sender, amount0, amount1, shares);
    }

    /// @notice Burn LP shares for pro-rata share of current hook holdings.
    function redeem(uint256 shares)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 bal = sharesOf[msg.sender];
        if (shares == 0) revert ZeroAmount();
        if (shares > bal) revert InsufficientShares(shares, bal);

        uint256 bal0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 bal1 = IERC20(TOKEN1).balanceOf(address(this));

        amount0 = (bal0 * shares) / totalShares;
        amount1 = (bal1 * shares) / totalShares;

        sharesOf[msg.sender] = bal - shares;
        totalShares -= shares;

        if (amount0 > 0) IERC20(TOKEN0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(TOKEN1).safeTransfer(msg.sender, amount1);

        emit Redeemed(msg.sender, shares, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:               false,
            afterInitialize:                false,
            beforeAddLiquidity:             true,   // route v4-native LP through our deposit()
            afterAddLiquidity:              false,
            beforeRemoveLiquidity:          true,   // route v4-native LP through our redeem()
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

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external view override returns (bytes4)
    {
        _assertKey(key);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4)
    {
        revert HookNotEnabled(IHooks.afterInitialize.selector);
    }

    /// @notice v4-native LP adds are routed through the hook's `deposit()`
    ///         function instead. We block direct adds via PoolManager to keep
    ///         all liquidity accounted for under our share system.
    function beforeAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeAddLiquidity.selector);
    }

    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterAddLiquidity.selector);
    }

    function beforeRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeRemoveLiquidity.selector);
    }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterRemoveLiquidity.selector);
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        _assertKey(key);

        if (params.amountSpecified > 0) {
            // exactOutput not yet supported
            revert HookNotEnabled(IHooks.beforeSwap.selector);
        }
        uint256 amountIn = uint256(-params.amountSpecified);

        (address inputToken, address outputToken, Currency inputCurrency, Currency outputCurrency) =
            params.zeroForOne
                ? (TOKEN0, TOKEN1, key.currency0, key.currency1)
                : (TOKEN1, TOKEN0, key.currency1, key.currency0);

        // Pre-swap reserves
        uint256 reserveIn  = IERC20(inputToken).balanceOf(address(this));
        uint256 reserveOut = IERC20(outputToken).balanceOf(address(this));

        // Pyth-only mid here (RedStone payload doesn't flow through v4's hookData
        // path). Pyth confidence + staleness gates still apply.
        (uint256 midE18, ) = ORACLE.getMid(inputToken, outputToken);

        uint256 amountOut = _quote(amountIn, reserveIn, reserveOut, midE18, spreadBps, kBps);
        if (amountOut > reserveOut) {
            // Phase 2.6: this is where JIT-borrow from FxMarketRegistry kicks in.
            revert InsufficientLiquidity(reserveOut, amountOut);
        }

        inputCurrency.take(POOL_MANAGER, address(this), amountIn, false);
        outputCurrency.settle(POOL_MANAGER, address(this), amountOut, false);

        emit Swapped(
            msg.sender,
            inputCurrency,
            outputCurrency,
            amountIn,
            amountOut,
            midE18,
            reserveIn,
            reserveOut
        );

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(amountIn)),
            -int128(int256(amountOut))
        );
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    function afterSwap(
        address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata
    ) external view override onlyPoolManager returns (bytes4, int128) {
        // Phase 2.6: route accrued fees as additional Morpho supply for the
        // appropriate market (the Bunni rehypothecation pattern).
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
                              PMM QUOTE
    //////////////////////////////////////////////////////////////*/

    /// @notice Oracle-anchored quote with size-impact slippage.
    /// @dev    `amountOut = amountIn * mid * (1 - spread/10_000) * (1 - kImpact)`
    ///         where `kImpact = k * amountIn / (reserveIn + amountIn) / 10_000`.
    ///
    ///   - At `amountIn << reserveIn`: impact ~ 0, price = mid * (1 - spread)
    ///   - At `amountIn = reserveIn`:  impact = k * 0.5 / 10_000
    ///   - At `amountIn -> infinity`:  impact -> k / 10_000 (asymptote)
    function _quote(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 midE18,
        uint16  spread,
        uint16  k
    ) internal pure returns (uint256 amountOut) {
        // Base output at oracle mid minus constant spread
        uint256 spreadAdj = uint256(10_000 - spread);
        uint256 baseOut = (amountIn * midE18 * spreadAdj) / 1e18 / 10_000;

        if (k == 0 || amountIn == 0) {
            return baseOut;
        }

        // Linear DODO-style size impact. Single division-by-denominator preserves
        // precision: impactNumerator / denominator <= baseOut * k / 10_000.
        uint256 denom = reserveIn + amountIn;
        if (denom == 0) return baseOut;
        uint256 impact = (baseOut * uint256(k) * amountIn) / denom / 10_000;
        if (impact > baseOut) return 0;
        amountOut = baseOut - impact;

        // We don't cap amountOut at reserveOut here — that's the caller's
        // responsibility (so the InsufficientLiquidity error carries the
        // requested amount, not the truncated one).
        reserveOut; // silence unused warning
    }

    /// @notice External view: quote a swap for off-chain or test introspection.
    function quote(uint256 amountIn, bool zeroForOne) external view returns (uint256 amountOut) {
        address inputToken  = zeroForOne ? TOKEN0 : TOKEN1;
        address outputToken = zeroForOne ? TOKEN1 : TOKEN0;
        uint256 reserveIn   = IERC20(inputToken).balanceOf(address(this));
        uint256 reserveOut  = IERC20(outputToken).balanceOf(address(this));
        (uint256 midE18, )  = ORACLE.getMid(inputToken, outputToken);
        return _quote(amountIn, reserveIn, reserveOut, midE18, spreadBps, kBps);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _assertKey(PoolKey calldata key) internal view {
        if (Currency.unwrap(key.currency0) != TOKEN0 || Currency.unwrap(key.currency1) != TOKEN1) {
            revert PoolKeyMismatch();
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ESCAPE HATCH
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner can sweep tokens that are NOT TOKEN0 or TOKEN1 (e.g. dust
    ///         airdrops, mis-sent ERC-20s). Cannot drain the pair tokens —
    ///         those belong to LPs.
    function sweepDust(address token, address to, uint256 amount) external onlyOwner {
        if (token == TOKEN0 || token == TOKEN1) revert HookNotEnabled(bytes4(0));
        IERC20(token).safeTransfer(to, amount);
    }
}
