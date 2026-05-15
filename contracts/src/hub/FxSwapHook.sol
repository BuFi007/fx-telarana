// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";
import {IFxMarketRegistry} from "../interfaces/IFxMarketRegistry.sol";

/// @title FxSwapHook
/// @notice Uniswap v4 hook for fx-Telarana FX swaps. Locked to a single
///         (TOKEN0, TOKEN1) pair. Oracle-anchored PMM-style pricing with
///         hook-owned LP accounting and Morpho Blue rehypothecation.
///
/// ## Phase 2.6 — rehypothecating PMM
///
/// LP capital is split per `hotReservePct`:
///   * Hot reserve in hook (default 20%): instantly available for swaps,
///     no per-swap gas penalty.
///   * Morpho supply (default 80%): held in the same-loan-asset Morpho
///     market (USDC→M2, EURC→M1), earning supply APY.
///
/// Effective reserves for PMM math = hot + Morpho supply assets. Swaps
/// JIT-withdraw from Morpho when hot reserve is insufficient. afterSwap
/// rebalances the input side back into Morpho so capital stays productive.
///
/// We track `morphoShares` per loan-token ourselves rather than reading
/// from Morpho on every call: cheaper, lets the contract work in mocked-
/// registry tests where no Morpho deployment exists.
///
/// ## What's still deferred (Phase 2.7+)
///
/// * Full DODO PMM curve with `B0/Q0` equilibrium tracking + regime
///   detection. Current linear approximation is acceptable for stable
///   pairs (USDC/EURC); volatile pairs need the integral.
/// * exactOutput swap path. Universal Router defaults to exactInput.
/// * True JIT-borrow against same-pair collateral. For the stable pair
///   the JIT-withdraw path is gas-cheaper and effectively equivalent.
/// * TWAMM order scheduling. Long-running institutional and future perp
///   hedging flows should settle through a separate router/hook module that
///   consumes this hook's liquidity and observation signal.
///
/// ## Oracle/volatility signal
///
/// The hook records a truncated, pair-canonical mid-price observation from
/// `IFxOracle(TOKEN0, TOKEN1)`. Sudden mid-price moves are clipped per
/// observation and converted into an additive spread. This is inspired by
/// Uniswap's truncated oracle and volatility oracle hook examples, but keeps
/// `IFxOracle` as the only price read path.
///
/// ## Permission bits
///
/// `beforeAddLiquidity` + `beforeRemoveLiquidity` REVERT — all LP flow
/// must go through `deposit`/`redeem`. `beforeSwap` + `afterSwap` +
/// `beforeSwapReturnDelta` enable the PMM. Mine the deploy address with
/// `HookMiner` so the low-order bits match `getHookPermissions`.
///
/// Data flow:
///   LP deposit / v4 swap
///       |
///       v
///   FxSwapHook -- read IFxOracle + PMM quote --> Uniswap v4 PoolManager
///       |
///       +-- hot reserve / JIT withdraw -------> Morpho Blue via registry params
///       |
///       v
///   swap output delivered; idle input rehypothecated
contract FxSwapHook is IHooks, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencySettler for Currency;
    using MarketParamsLib for MorphoMarketParams;
    using MorphoBalancesLib for IMorpho;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IPoolManager      public immutable POOL_MANAGER;
    IFxOracle         public immutable ORACLE;
    IFxMarketRegistry public immutable REGISTRY;
    IMorpho           public immutable MORPHO;

    /// @notice Pair tokens. TOKEN0 < TOKEN1 by address.
    address public immutable TOKEN0;
    address public immutable TOKEN1;
    uint8 public immutable TOKEN0_DECIMALS;
    uint8 public immutable TOKEN1_DECIMALS;

    /*//////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    /// @notice PMM knobs (see _quote).
    uint16 public spreadBps;
    uint16 public kBps;
    uint16 public maxObservationChangeBps;
    uint16 public volatilitySpreadMultiplierBps;

    /// @notice Fraction of LP value kept as hot reserve in the hook (bps).
    ///         Remainder is rehypothecated into Morpho. 0 = full
    ///         rehypothecation, 10_000 = 100% hot (Morpho integration
    ///         skipped entirely).
    uint16 public hotReservePct;

    uint16 public constant MAX_SPREAD_BPS  = 500;
    uint16 public constant MAX_K_BPS       = 1_000;
    uint16 public constant DEFAULT_SPREAD_BPS  = 30;
    uint16 public constant DEFAULT_K_BPS       = 50;
    uint16 public constant DEFAULT_HOT_RESERVE_PCT = 2_000;  // 20%
    uint16 public constant DEFAULT_MAX_OBSERVATION_CHANGE_BPS = 100; // 1%
    uint16 public constant DEFAULT_VOLATILITY_SPREAD_MULTIPLIER_BPS = 10_000; // 1x
    uint16 public constant MAX_OBSERVATION_CHANGE_BPS = 1_000; // 10%
    uint16 public constant MAX_VOLATILITY_SPREAD_MULTIPLIER_BPS = 50_000; // 5x
    uint16 public constant OBSERVATION_CARDINALITY = 256;

    /// @notice Truncated oracle observation used by swaps and future risk consumers.
    struct OracleObservation {
        /// @dev Block timestamp for the observation.
        uint32 timestamp;
        /// @dev Truncated TOKEN0/TOKEN1 mid, 1e18-scaled.
        uint224 midE18;
        /// @dev Truncated move from the previous observation.
        uint16 volatilityBps;
        /// @dev Spread that swaps use after volatility add-on.
        uint16 effectiveSpreadBps;
    }

    OracleObservation[OBSERVATION_CARDINALITY] public oracleObservations;
    uint16 public oracleObservationIndex;
    uint16 public oracleObservationCardinality;
    uint256 public latestTruncatedMidE18;
    uint16 public latestVolatilityBps;

    /// @notice Our own bookkeeping of Morpho supply shares per loan token.
    ///         loanToken → supply shares held by this contract. Updated on
    ///         every supply/withdraw the hook performs internally.
    mapping(address loanToken => uint256 shares) public morphoShares;

    /*//////////////////////////////////////////////////////////////
                                LP STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotPoolManager();
    error NotOwner();
    error ZeroAddress();
    error SpreadOutOfRange(uint16 requested, uint16 maxBps);
    error KOutOfRange(uint16 requested, uint16 maxBps);
    error HotReservePctOutOfRange(uint16 requested);
    error ObservationChangeOutOfRange(uint16 requested, uint16 maxBps);
    error VolatilityMultiplierOutOfRange(uint16 requested, uint16 maxBps);
    error HookNotEnabled(bytes4 hook);
    error PoolKeyMismatch();
    error InsufficientLiquidity(uint256 effectiveReserveOut, uint256 amountOutRequested);
    error InsufficientShares(uint256 requested, uint256 available);
    error ZeroAmount();
    error TokensNotSorted();
    error InvalidSellToken(address sellToken);
    error DecimalsOutOfRange(address token, uint8 decimals);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SpreadSet(uint16 oldBps, uint16 newBps);
    event KSet(uint16 oldBps, uint16 newBps);
    event HotReservePctSet(uint16 oldBps, uint16 newBps);
    event OracleGuardrailsSet(
        uint16 oldMaxObservationChangeBps,
        uint16 newMaxObservationChangeBps,
        uint16 oldVolatilitySpreadMultiplierBps,
        uint16 newVolatilitySpreadMultiplierBps
    );
    event OracleObservationRecorded(
        uint16 indexed index,
        uint32 timestamp,
        uint256 rawMidE18,
        uint256 truncatedMidE18,
        uint16 volatilityBps,
        uint16 effectiveSpreadBps
    );
    event Deposited(address indexed lp, uint256 amount0, uint256 amount1, uint256 shares);
    event Redeemed(address indexed lp, uint256 shares, uint256 amount0, uint256 amount1);
    event Rehypothecated(address indexed loanToken, uint256 assetsSupplied, uint256 sharesAfter);
    event Withdrawn(address indexed loanToken, uint256 assetsWithdrawn, uint256 sharesAfter);
    event Swapped(
        address indexed sender,
        Currency indexed input,
        Currency indexed output,
        uint256 amountIn,
        uint256 amountOut,
        uint256 midE18,
        uint256 effectiveReserveIn,
        uint256 effectiveReserveOut
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

    /// @dev `morpho_` is read off the registry for convenience, so we don't
    ///      have to keep two addresses in sync. Pass the Morpho address that
    ///      the registry was constructed with.
    constructor(
        address poolManager_,
        address oracle_,
        address registry_,
        address owner_,
        address token0_,
        address token1_,
        address morpho_
    ) {
        if (
            poolManager_ == address(0) || oracle_ == address(0) || registry_ == address(0)
                || owner_ == address(0) || token0_ == address(0) || token1_ == address(0)
                || morpho_ == address(0)
        ) revert ZeroAddress();
        if (token0_ >= token1_) revert TokensNotSorted();

        POOL_MANAGER  = IPoolManager(poolManager_);
        ORACLE        = IFxOracle(oracle_);
        REGISTRY      = IFxMarketRegistry(registry_);
        MORPHO        = IMorpho(morpho_);
        owner         = owner_;
        TOKEN0        = token0_;
        TOKEN1        = token1_;
        TOKEN0_DECIMALS = _readDecimals(token0_);
        TOKEN1_DECIMALS = _readDecimals(token1_);
        spreadBps     = DEFAULT_SPREAD_BPS;
        kBps          = DEFAULT_K_BPS;
        hotReservePct = DEFAULT_HOT_RESERVE_PCT;
        maxObservationChangeBps = DEFAULT_MAX_OBSERVATION_CHANGE_BPS;
        volatilitySpreadMultiplierBps = DEFAULT_VOLATILITY_SPREAD_MULTIPLIER_BPS;
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

    /// @notice 0 = full rehypothecation. 10_000 = pure hot reserves
    ///         (Morpho path skipped entirely). Default 2000 = 20% hot.
    function setHotReservePct(uint16 newBps) external onlyOwner {
        if (newBps > 10_000) revert HotReservePctOutOfRange(newBps);
        emit HotReservePctSet(hotReservePct, newBps);
        hotReservePct = newBps;
    }

    function setOracleGuardrails(uint16 newMaxObservationChangeBps, uint16 newVolatilitySpreadMultiplierBps)
        external
        onlyOwner
    {
        if (newMaxObservationChangeBps > MAX_OBSERVATION_CHANGE_BPS) {
            revert ObservationChangeOutOfRange(newMaxObservationChangeBps, MAX_OBSERVATION_CHANGE_BPS);
        }
        if (newVolatilitySpreadMultiplierBps > MAX_VOLATILITY_SPREAD_MULTIPLIER_BPS) {
            revert VolatilityMultiplierOutOfRange(
                newVolatilitySpreadMultiplierBps, MAX_VOLATILITY_SPREAD_MULTIPLIER_BPS
            );
        }
        emit OracleGuardrailsSet(
            maxObservationChangeBps,
            newMaxObservationChangeBps,
            volatilitySpreadMultiplierBps,
            newVolatilitySpreadMultiplierBps
        );
        maxObservationChangeBps = newMaxObservationChangeBps;
        volatilitySpreadMultiplierBps = newVolatilitySpreadMultiplierBps;
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /// @notice Manual rebalance (owner-callable). Useful after admin changes
    ///         hotReservePct, or to clear up drift caused by donations.
    function rebalance() external onlyOwner {
        _rebalanceToken(TOKEN0);
        _rebalanceToken(TOKEN1);
    }

    /// @notice Permissionless keeper entrypoint that records the pair-canonical
    ///         truncated oracle observation without executing a swap.
    function recordOracleObservation()
        external
        returns (uint256 rawMidE18, uint256 truncatedMidE18, uint16 volatilityBps, uint16 effectiveSpread)
    {
        (rawMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (truncatedMidE18, volatilityBps, effectiveSpread) = _recordObservation(rawMidE18);
    }

    function previewOracleObservation()
        external
        view
        returns (uint256 rawMidE18, uint256 truncatedMidE18, uint16 volatilityBps, uint16 effectiveSpread)
    {
        (rawMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (truncatedMidE18, volatilityBps, effectiveSpread) = _previewObservation(rawMidE18);
    }

    /*//////////////////////////////////////////////////////////////
                                LP API
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 amount0, uint256 amount1)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        // Capture pre-deposit total assets (hot + Morpho).
        uint256 t0Before = _totalAssets(TOKEN0);
        uint256 t1Before = _totalAssets(TOKEN1);

        if (amount0 > 0) IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), amount1);

        if (totalShares == 0) {
            shares = amount0 + amount1;
            if (shares <= MINIMUM_LIQUIDITY) revert ZeroAmount();
            shares -= MINIMUM_LIQUIDITY;
            sharesOf[address(0)] += MINIMUM_LIQUIDITY;
            totalShares          += MINIMUM_LIQUIDITY;
        } else {
            uint256 s0 = t0Before == 0 ? type(uint256).max : (amount0 * totalShares) / t0Before;
            uint256 s1 = t1Before == 0 ? type(uint256).max : (amount1 * totalShares) / t1Before;
            shares = s0 < s1 ? s0 : s1;
            if (shares == 0) revert ZeroAmount();
        }

        sharesOf[msg.sender] += shares;
        totalShares          += shares;

        emit Deposited(msg.sender, amount0, amount1, shares);

        // Rehypothecate excess hot into Morpho.
        _rebalanceToken(TOKEN0);
        _rebalanceToken(TOKEN1);
    }

    function redeem(uint256 shares)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroAmount();
        uint256 bal = sharesOf[msg.sender];
        if (shares > bal) revert InsufficientShares(shares, bal);

        amount0 = (_totalAssets(TOKEN0) * shares) / totalShares;
        amount1 = (_totalAssets(TOKEN1) * shares) / totalShares;

        sharesOf[msg.sender] = bal - shares;
        totalShares -= shares;

        // Top up hot reserves from Morpho if needed.
        if (amount0 > 0) _ensureHotBalance(TOKEN0, amount0);
        if (amount1 > 0) _ensureHotBalance(TOKEN1, amount1);

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
            beforeAddLiquidity:             true,
            afterAddLiquidity:              false,
            beforeRemoveLiquidity:          true,
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
            revert HookNotEnabled(IHooks.beforeSwap.selector);
        }
        uint256 amountIn = uint256(-params.amountSpecified);

        (address inputToken, address outputToken, Currency inputCurrency, Currency outputCurrency) =
            params.zeroForOne
                ? (TOKEN0, TOKEN1, key.currency0, key.currency1)
                : (TOKEN1, TOKEN0, key.currency1, key.currency0);

        // Effective reserves = hot + Morpho-supplied assets.
        uint256 hotOut       = IERC20(outputToken).balanceOf(address(this));
        uint256 morphoOut    = _morphoSupplyAssets(outputToken);
        uint256 effReserveIn  = IERC20(inputToken).balanceOf(address(this)) + _morphoSupplyAssets(inputToken);
        uint256 effReserveOut = hotOut + morphoOut;

        (uint256 canonicalMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (uint256 truncatedCanonicalMidE18,, uint16 dynamicSpreadBps) = _recordObservation(canonicalMidE18);
        uint256 midE18 = params.zeroForOne ? truncatedCanonicalMidE18 : _invertE18(truncatedCanonicalMidE18);
        uint8 inputDecimals = params.zeroForOne ? TOKEN0_DECIMALS : TOKEN1_DECIMALS;
        uint8 outputDecimals = params.zeroForOne ? TOKEN1_DECIMALS : TOKEN0_DECIMALS;
        uint256 amountOut =
            _quote(amountIn, effReserveIn, effReserveOut, midE18, dynamicSpreadBps, kBps, inputDecimals, outputDecimals);

        if (amountOut > effReserveOut) {
            revert InsufficientLiquidity(effReserveOut, amountOut);
        }

        // JIT-withdraw from Morpho if hot reserve insufficient.
        if (amountOut > hotOut) {
            _withdrawFromMorphoAssets(outputToken, amountOut - hotOut);
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
            effReserveIn,
            effReserveOut
        );

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            amountIn.toInt256().toInt128(),
            -amountOut.toInt256().toInt128()
        );
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // After swap: input-side balance grew (we just took amountIn from user).
        // Push the excess into Morpho so capital keeps earning supply APY.
        address inputToken = params.zeroForOne ? TOKEN0 : TOKEN1;
        _rebalanceToken(inputToken);
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

    /// @notice See FxSwapHook.md for the math. Linear DODO-style size-impact
    ///         on top of an oracle-anchored mid.
    function _quote(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 midE18,
        uint16  spread,
        uint16  k,
        uint8   inputDecimals,
        uint8   outputDecimals
    ) internal pure returns (uint256 amountOut) {
        uint256 spreadAdj = uint256(10_000 - spread);
        uint256 amountInE18 = _rawToE18(amountIn, inputDecimals);
        uint256 baseOutE18 = (amountInE18 * midE18 * spreadAdj) / 1e18 / 10_000;
        uint256 baseOut = _e18ToRaw(baseOutE18, outputDecimals);

        if (k == 0 || amountIn == 0) return baseOut;

        uint256 denom = reserveIn + amountIn;
        if (denom == 0) return baseOut;
        uint256 impact = (baseOut * uint256(k) * amountIn) / denom / 10_000;
        if (impact > baseOut) return 0;
        amountOut = baseOut - impact;

        reserveOut;
    }

    function quote(uint256 amountIn, bool zeroForOne) external view returns (uint256 amountOut) {
        address inputToken  = zeroForOne ? TOKEN0 : TOKEN1;
        address outputToken = zeroForOne ? TOKEN1 : TOKEN0;
        uint256 reserveIn   = _totalAssets(inputToken);
        uint256 reserveOut  = _totalAssets(outputToken);
        (uint256 rawCanonicalMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (uint256 truncatedCanonicalMidE18,, uint16 dynamicSpreadBps) = _previewObservation(rawCanonicalMidE18);
        uint256 midE18 = zeroForOne ? truncatedCanonicalMidE18 : _invertE18(truncatedCanonicalMidE18);
        uint8 inputDecimals = zeroForOne ? TOKEN0_DECIMALS : TOKEN1_DECIMALS;
        uint8 outputDecimals = zeroForOne ? TOKEN1_DECIMALS : TOKEN0_DECIMALS;
        return _quote(amountIn, reserveIn, reserveOut, midE18, dynamicSpreadBps, kBps, inputDecimals, outputDecimals);
    }

    /// @notice Token-addressed exact-input quote — spec §6.1 integrator surface.
    /// @dev    Wrapper around `quote(amountIn, zeroForOne)` that derives the direction
    ///         flag from `sellToken`. Reverts if `sellToken` is not one of this hook's
    ///         locked pair tokens.
    /// @return buyAmount       Output amount of the other pair token (post-spread).
    /// @return oraclePriceE18  The mid price used in the quote (1e18-scaled, sell/buy).
    function quoteExactInput(address sellToken, uint256 sellAmount)
        external
        view
        returns (uint256 buyAmount, uint256 oraclePriceE18)
    {
        if (sellToken != TOKEN0 && sellToken != TOKEN1) revert InvalidSellToken(sellToken);
        bool zeroForOne = (sellToken == TOKEN0);
        address buyToken = zeroForOne ? TOKEN1 : TOKEN0;
        uint256 reserveIn  = _totalAssets(sellToken);
        uint256 reserveOut = _totalAssets(buyToken);
        (uint256 rawCanonicalMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (uint256 truncatedCanonicalMidE18,, uint16 dynamicSpreadBps) = _previewObservation(rawCanonicalMidE18);
        oraclePriceE18 = zeroForOne ? truncatedCanonicalMidE18 : _invertE18(truncatedCanonicalMidE18);
        (uint8 inputDecimals, uint8 outputDecimals) = _decimalsFor(sellToken, buyToken);
        buyAmount = _quote(
            sellAmount,
            reserveIn,
            reserveOut,
            oraclePriceE18,
            dynamicSpreadBps,
            kBps,
            inputDecimals,
            outputDecimals
        );
    }

    function effectiveSpreadBps() external view returns (uint16) {
        return _effectiveSpreadBps(latestVolatilityBps);
    }

    /*//////////////////////////////////////////////////////////////
                              MORPHO INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Total assets the hook controls for `loanToken` = hot + Morpho.
    function _totalAssets(address loanToken) internal view returns (uint256) {
        return IERC20(loanToken).balanceOf(address(this)) + _morphoSupplyAssets(loanToken);
    }

    /// @notice Morpho supply assets for the market where `loanToken` is the
    ///         loan side. Short-circuits to 0 if we've never supplied,
    ///         so mocked-Morpho tests don't have to stub view calls.
    function _morphoSupplyAssets(address loanToken) internal view returns (uint256) {
        if (morphoShares[loanToken] == 0) return 0;
        MorphoMarketParams memory mp = _morphoParamsFor(loanToken);
        return MORPHO.expectedSupplyAssets(mp, address(this));
    }

    /// @notice Build Morpho-side MarketParams for `loanToken` from the registry.
    function _morphoParamsFor(address loanToken) internal view returns (MorphoMarketParams memory) {
        address collateral = (loanToken == TOKEN0) ? TOKEN1 : TOKEN0;
        IFxMarketRegistry.MarketParams memory p = REGISTRY.paramsOf(loanToken, collateral);
        return MorphoMarketParams({
            loanToken: p.loanToken,
            collateralToken: p.collateralToken,
            oracle: p.oracle,
            irm: p.irm,
            lltv: p.lltv
        });
    }

    /// @notice Supply `assets` into Morpho's market for `loanToken`.
    function _supplyToMorpho(address loanToken, uint256 assets) internal {
        if (assets == 0) return;
        MorphoMarketParams memory mp = _morphoParamsFor(loanToken);
        _ensureApproval(IERC20(loanToken), address(MORPHO), assets);
        (, uint256 sharesSupplied) = MORPHO.supply(mp, assets, 0, address(this), "");
        morphoShares[loanToken] += sharesSupplied;
        emit Rehypothecated(loanToken, assets, morphoShares[loanToken]);
    }

    /// @notice Withdraw at least `assets` from Morpho's market for `loanToken`.
    function _withdrawFromMorphoAssets(address loanToken, uint256 assets) internal {
        if (assets == 0) return;
        MorphoMarketParams memory mp = _morphoParamsFor(loanToken);
        (, uint256 sharesBurned) = MORPHO.withdraw(mp, assets, 0, address(this), address(this));
        uint256 held = morphoShares[loanToken];
        morphoShares[loanToken] = sharesBurned > held ? 0 : held - sharesBurned;
        emit Withdrawn(loanToken, assets, morphoShares[loanToken]);
    }

    /// @notice Pull `needed` of `token` into hot reserve if missing.
    function _ensureHotBalance(address token, uint256 needed) internal {
        uint256 hot = IERC20(token).balanceOf(address(this));
        if (hot >= needed) return;
        _withdrawFromMorphoAssets(token, needed - hot);
    }

    /// @notice Push hot excess of `loanToken` into Morpho supply. Skips
    ///         entirely when hotReservePct = 100% or when supplying 0.
    function _rebalanceToken(address loanToken) internal {
        if (hotReservePct >= 10_000) return;
        uint256 hot = IERC20(loanToken).balanceOf(address(this));
        uint256 supplied = _morphoSupplyAssets(loanToken);
        uint256 total = hot + supplied;
        if (total == 0) return;
        uint256 targetHot = (total * uint256(hotReservePct)) / 10_000;
        if (hot > targetHot) {
            _supplyToMorpho(loanToken, hot - targetHot);
        }
    }

    function _ensureApproval(IERC20 token, address spender, uint256 needed) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current < needed) {
            if (current != 0) token.forceApprove(spender, 0);
            token.forceApprove(spender, type(uint256).max);
        }
    }

    function _rawToE18(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        return amount * (10 ** uint256(18 - decimals_));
    }

    function _e18ToRaw(uint256 amountE18, uint8 decimals_) internal pure returns (uint256) {
        return amountE18 / (10 ** uint256(18 - decimals_));
    }

    function _readDecimals(address token) internal view returns (uint8 decimals_) {
        decimals_ = IERC20Metadata(token).decimals();
        if (decimals_ > 18) revert DecimalsOutOfRange(token, decimals_);
    }

    function _decimalsFor(address inputToken, address outputToken)
        internal
        view
        returns (uint8 inputDecimals, uint8 outputDecimals)
    {
        inputDecimals = inputToken == TOKEN0 ? TOKEN0_DECIMALS : TOKEN1_DECIMALS;
        outputDecimals = outputToken == TOKEN0 ? TOKEN0_DECIMALS : TOKEN1_DECIMALS;
    }

    function _recordObservation(uint256 rawMidE18)
        internal
        returns (uint256 truncatedMidE18, uint16 volatilityBps, uint16 effectiveSpread)
    {
        uint32 timestamp = uint32(block.timestamp);
        if (oracleObservationCardinality != 0 && oracleObservations[oracleObservationIndex].timestamp == timestamp) {
            truncatedMidE18 = latestTruncatedMidE18;
            volatilityBps = latestVolatilityBps;
            effectiveSpread = _effectiveSpreadBps(volatilityBps);
            return (truncatedMidE18, volatilityBps, effectiveSpread);
        }

        (truncatedMidE18, volatilityBps, effectiveSpread) = _previewObservation(rawMidE18);

        uint16 nextIndex = oracleObservationCardinality == 0
            ? 0
            : uint16((uint256(oracleObservationIndex) + 1) % uint256(OBSERVATION_CARDINALITY));
        oracleObservations[nextIndex] = OracleObservation({
            timestamp: timestamp,
            midE18: truncatedMidE18.toUint224(),
            volatilityBps: volatilityBps,
            effectiveSpreadBps: effectiveSpread
        });
        oracleObservationIndex = nextIndex;
        if (oracleObservationCardinality < OBSERVATION_CARDINALITY) {
            oracleObservationCardinality += 1;
        }
        latestTruncatedMidE18 = truncatedMidE18;
        latestVolatilityBps = volatilityBps;

        emit OracleObservationRecorded(
            nextIndex, timestamp, rawMidE18, truncatedMidE18, volatilityBps, effectiveSpread
        );
    }

    function _previewObservation(uint256 rawMidE18)
        internal
        view
        returns (uint256 truncatedMidE18, uint16 volatilityBps, uint16 effectiveSpread)
    {
        uint256 previous = latestTruncatedMidE18;
        if (previous == 0) {
            return (rawMidE18, 0, _effectiveSpreadBps(0));
        }

        uint256 maxDelta = (previous * uint256(maxObservationChangeBps)) / 10_000;
        if (rawMidE18 > previous + maxDelta) {
            truncatedMidE18 = previous + maxDelta;
        } else if (rawMidE18 + maxDelta < previous) {
            truncatedMidE18 = previous - maxDelta;
        } else {
            truncatedMidE18 = rawMidE18;
        }

        uint256 delta = rawMidE18 > previous ? truncatedMidE18 - previous : previous - truncatedMidE18;
        uint256 vol = previous == 0 ? 0 : (delta * 10_000) / previous;
        if (vol > type(uint16).max) vol = type(uint16).max;
        volatilityBps = vol.toUint16();
        effectiveSpread = _effectiveSpreadBps(volatilityBps);
    }

    function _effectiveSpreadBps(uint16 volatilityBps) internal view returns (uint16) {
        uint256 addOn = (uint256(volatilityBps) * uint256(volatilitySpreadMultiplierBps)) / 10_000;
        uint256 total = uint256(spreadBps) + addOn;
        if (total > MAX_SPREAD_BPS) total = MAX_SPREAD_BPS;
        return total.toUint16();
    }

    function _invertE18(uint256 midE18) internal pure returns (uint256) {
        return (1e18 * 1e18) / midE18;
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

    function sweepDust(address token, address to, uint256 amount) external onlyOwner {
        if (token == TOKEN0 || token == TOKEN1) revert HookNotEnabled(bytes4(0));
        IERC20(token).safeTransfer(to, amount);
    }
}
