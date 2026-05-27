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

import {PMMPricing} from "dodo-pmm/PMMPricing.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";
import {IFxMarketRegistry} from "../interfaces/IFxMarketRegistry.sol";
import {ITurboFeeVault} from "../interfaces/ITurboFeeVault.sol";

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
/// ## Phase 2.7 — DODO PMM curve
///
/// Pricing math is the vendored DODO V2 Proactive Market Maker
/// (`contracts/lib/dodo-pmm-08/PMMPricing.sol`, Apache-2.0, audited via
/// Abracadabra MIMSwap). The hook tracks two equilibrium reserves
/// `baseTargetE18` (B0) and `quoteTargetE18` (Q0) — what the protocol
/// considers fair-priced reserves at oracle mid `i`. The current state
/// (B, Q, B0, Q0, i, K) maps to a `RState` regime — ONE / ABOVE_ONE /
/// BELOW_ONE — and `PMMPricing.sellBaseToken / sellQuoteToken` quote
/// the curve closed-form per regime.
///
/// `kBps` is mapped to DODO's `K` via `K = uint256(kBps) * 1e14`, so
/// kBps ∈ [0, 1000] → K ∈ [0, 1e17] (10% maximum curvature). Volatility
/// and base spread bps are applied *on top* of the PMM output as an
/// LP-fee channel, so the Bunni-style fee sleeve (Phase 2.7 #3) can
/// plug into the same hook point without disturbing PMM accounting.
///
/// ## What's still deferred (Phase 2.7+)
///
/// * exactOutput swap path. Universal Router defaults to exactInput.
///   The DODO inverse (`_SolveQuadraticFunctionForTarget`) is available
///   in the vendored library; the surface gets re-cut once needed.
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

    /// @notice Optional TurboFeeVault integration — when set, protocol fees
    ///         can be routed to the vault via depositFee(). See TODO below.
    ITurboFeeVault public feeVault;

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

    /// @notice DODO PMM equilibrium targets, 1e18-normalized regardless of
    ///         TOKEN0/TOKEN1 native decimals. B0 tracks the protocol's notion
    ///         of "where base reserves should be at mid"; Q0 the analogue for
    ///         quote. Updated proportionally on `deposit`/`redeem`.
    uint256 public baseTargetE18;
    uint256 public quoteTargetE18;

    /// @notice Protocol fee sleeve — accrued fees claimable by the treasury
    ///         ahead of LPs. Pattern mirrors Balancer V2's `ProtocolFeesCollector`:
    ///         a fraction `protocolFeeBps` of every swap's spread is held in a
    ///         separate accumulator that LP-share redemption deducts before
    ///         pro-rating. Fees physically remain in the hook's hot+Morpho
    ///         balance, so they earn supply APY until claimed.
    uint256 public protocolFee0;
    uint256 public protocolFee1;
    address public treasury;
    uint16 public protocolFeeBps;
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 5_000; // 50% of swap fee max

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
    error NotTreasury();
    error ProtocolFeeOutOfRange(uint16 requested, uint16 maxBps);
    error InvalidToken(address token);
    error AmountExceedsProtocolFee(uint256 requested, uint256 available);
    error SyncDriftTooLarge(uint256 actual, uint256 expected, uint256 maxDriftBps);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeeVaultSet(address indexed feeVault);
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
    event TargetsAdjusted(uint256 newBaseTargetE18, uint256 newQuoteTargetE18);
    event ProtocolFeeBpsSet(uint16 oldBps, uint16 newBps);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeeAccrued(address indexed token, uint256 amount, uint256 totalAccrued);
    event ProtocolFeeClaimed(address indexed token, address indexed to, uint256 amount, uint256 remaining);
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

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
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
        treasury      = owner_;          // safe default; owner can rotate later
        // protocolFeeBps stays 0 by default → backwards-compatible: no fees
        // siphoned until the owner explicitly opts in.
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

    /// @notice Owner sets the fraction of each swap fee that accrues to the
    ///         protocol fee sleeve. Maximum 50% (`MAX_PROTOCOL_FEE_BPS`).
    function setProtocolFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeOutOfRange(newBps, MAX_PROTOCOL_FEE_BPS);
        emit ProtocolFeeBpsSet(protocolFeeBps, newBps);
        protocolFeeBps = newBps;
    }

    /// @notice Owner rotates the treasury that may withdraw protocol fees.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Set the TurboFeeVault for routing swap fees.
    ///         Pass address(0) to disable fee routing.
    function setFeeVault(address feeVault_) external onlyOwner {
        feeVault = ITurboFeeVault(feeVault_);
        emit FeeVaultSet(feeVault_);
    }

    // TODO: Wire feeVault.depositFee() into the protocol fee accrual path.
    // The swap fee is currently accrued to protocolFee0/protocolFee1 and
    // claimed manually by the treasury via claimProtocolFees(). To route
    // fees to TurboFeeVault, the claimProtocolFees path should optionally
    // call feeVault.depositFee(token, amount, poolId) when feeVault != 0.

    /// @notice Treasury withdraws accumulated protocol fees. JIT-withdraws
    ///         from Morpho when hot reserves are insufficient.
    function claimProtocolFees(address token, address to, uint256 amount)
        external
        onlyTreasury
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 available;
        if (token == TOKEN0) {
            available = protocolFee0;
            if (amount > available) revert AmountExceedsProtocolFee(amount, available);
            protocolFee0 = available - amount;
        } else if (token == TOKEN1) {
            available = protocolFee1;
            if (amount > available) revert AmountExceedsProtocolFee(amount, available);
            protocolFee1 = available - amount;
        } else {
            revert InvalidToken(token);
        }

        _ensureHotBalance(token, amount);
        IERC20(token).safeTransfer(to, amount);
        emit ProtocolFeeClaimed(token, to, amount, available - amount);
    }

    /// @notice Manual rebalance (owner-callable). Useful after admin changes
    ///         hotReservePct, or to clear up drift caused by donations.
    function rebalance() external onlyOwner {
        _rebalanceToken(TOKEN0);
        _rebalanceToken(TOKEN1);
    }

    /// @notice Snap the PMM equilibrium targets to current tradable reserves.
    ///         Owner-gated AND front-running-protected via expected-targets
    ///         + max-drift parameters (Uniswap-style slippage envelope). If
    ///         a mempool actor swaps before this call lands, the actual
    ///         snapshot will diverge from `expectedBase/Quote` beyond
    ///         `maxDriftBps` and the call reverts — preventing sync from
    ///         being used as an inventory-reset primitive against the curve.
    /// @param  expectedBaseTargetE18  Owner's predicted post-sync baseTarget.
    /// @param  expectedQuoteTargetE18 Owner's predicted post-sync quoteTarget.
    /// @param  maxDriftBps            Max divergence in basis points
    ///         (10_000 = 100%). Smaller values harden against sandwich.
    function sync(
        uint256 expectedBaseTargetE18,
        uint256 expectedQuoteTargetE18,
        uint256 maxDriftBps
    ) external onlyOwner nonReentrant {
        uint256 newBaseTargetE18  = _rawToE18(_tradableAssets(TOKEN0), TOKEN0_DECIMALS);
        uint256 newQuoteTargetE18 = _rawToE18(_tradableAssets(TOKEN1), TOKEN1_DECIMALS);
        if (newBaseTargetE18 == 0 || newQuoteTargetE18 == 0) revert ZeroAmount();
        _requireWithinDrift(newBaseTargetE18, expectedBaseTargetE18, maxDriftBps);
        _requireWithinDrift(newQuoteTargetE18, expectedQuoteTargetE18, maxDriftBps);
        baseTargetE18  = newBaseTargetE18;
        quoteTargetE18 = newQuoteTargetE18;
        emit TargetsAdjusted(newBaseTargetE18, newQuoteTargetE18);
    }

    /// @notice Revert if `actual` diverges from `expected` by more than
    ///         `maxDriftBps` basis points (in either direction).
    function _requireWithinDrift(uint256 actual, uint256 expected, uint256 maxDriftBps) internal pure {
        if (expected == 0) revert ZeroAmount();
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        // diff / expected > maxDriftBps / 10_000   ⇔   diff * 10_000 > expected * maxDriftBps
        if (diff * 10_000 > expected * maxDriftBps) revert SyncDriftTooLarge(actual, expected, maxDriftBps);
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
        // First deposit is owner-gated: anyone else doing it could lock the
        // PMM equilibrium at an arbitrary ratio, then later honest LPs deposit
        // at the (off-oracle) implied ratio and donate value to the attacker.
        // Subsequent deposits are permissionless.
        if (totalShares == 0 && msg.sender != owner) revert NotOwner();

        // Capture pre-deposit LP-tradable assets (= hot + Morpho − protocol
        // fee sleeve). Must mirror `redeem`: the treasury sleeve is claimable
        // ahead of LPs, so both entry and exit must exclude it. Otherwise new
        // LPs would mint at an inflated denominator and transfer value to
        // incumbents.
        uint256 t0Before = _tradableAssets(TOKEN0);
        uint256 t1Before = _tradableAssets(TOKEN1);

        if (amount0 > 0) IERC20(TOKEN0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(TOKEN1).safeTransferFrom(msg.sender, address(this), amount1);

        if (totalShares == 0) {
            // First deposit must seed both sides — otherwise the un-seeded
            // PMM target is zero and the pool is permanently locked, because
            // subsequent pro-rata target growth (`target *= shares/totalShares`)
            // can never escape zero. MINIMUM_LIQUIDITY burn also prevents a
            // clean re-bootstrap by redeeming the first LP.
            if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
            shares = amount0 + amount1;
            if (shares <= MINIMUM_LIQUIDITY) revert ZeroAmount();
            shares -= MINIMUM_LIQUIDITY;
            sharesOf[address(0)] += MINIMUM_LIQUIDITY;
            totalShares          += MINIMUM_LIQUIDITY;

            // First depositor seeds the PMM equilibrium at the deposit ratio.
            baseTargetE18  = _rawToE18(amount0, TOKEN0_DECIMALS);
            quoteTargetE18 = _rawToE18(amount1, TOKEN1_DECIMALS);
        } else {
            uint256 s0 = t0Before == 0 ? type(uint256).max : (amount0 * totalShares) / t0Before;
            uint256 s1 = t1Before == 0 ? type(uint256).max : (amount1 * totalShares) / t1Before;
            shares = s0 < s1 ? s0 : s1;
            if (shares == 0) revert ZeroAmount();

            // Targets grow with stake. Using the share ratio (vs. raw deposit
            // amounts) keeps the regime consistent across joins.
            uint256 totalSharesBefore = totalShares;
            baseTargetE18  = baseTargetE18  + (baseTargetE18  * shares) / totalSharesBefore;
            quoteTargetE18 = quoteTargetE18 + (quoteTargetE18 * shares) / totalSharesBefore;
        }

        sharesOf[msg.sender] += shares;
        totalShares          += shares;

        emit Deposited(msg.sender, amount0, amount1, shares);
        emit TargetsAdjusted(baseTargetE18, quoteTargetE18);

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

        uint256 totalSharesBefore = totalShares;
        // LP claim is on (totalAssets − protocolFee) — the treasury sleeve is
        // claimable ahead of LPs (Balancer V2 / Curve V2 admin-fee pattern).
        uint256 lpAssets0 = _totalAssets(TOKEN0);
        uint256 lpAssets1 = _totalAssets(TOKEN1);
        lpAssets0 = lpAssets0 > protocolFee0 ? lpAssets0 - protocolFee0 : 0;
        lpAssets1 = lpAssets1 > protocolFee1 ? lpAssets1 - protocolFee1 : 0;
        amount0 = (lpAssets0 * shares) / totalSharesBefore;
        amount1 = (lpAssets1 * shares) / totalSharesBefore;

        // Shrink targets pro-rata to the redeemed stake. Mirrors `deposit`.
        baseTargetE18  = baseTargetE18  - (baseTargetE18  * shares) / totalSharesBefore;
        quoteTargetE18 = quoteTargetE18 - (quoteTargetE18 * shares) / totalSharesBefore;

        sharesOf[msg.sender] = bal - shares;
        totalShares -= shares;

        // Top up hot reserves from Morpho if needed. Tradable variant so we
        // do not consume the protocol-fee sleeve to pay an LP — that would
        // make `claimProtocolFees` Morpho-dependent for an already-accrued
        // balance.
        if (amount0 > 0) _ensureHotTradable(TOKEN0, amount0);
        if (amount1 > 0) _ensureHotTradable(TOKEN1, amount1);

        if (amount0 > 0) IERC20(TOKEN0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(TOKEN1).safeTransfer(msg.sender, amount1);

        emit Redeemed(msg.sender, shares, amount0, amount1);
        emit TargetsAdjusted(baseTargetE18, quoteTargetE18);
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

        // NB: Donations / bilateral Morpho yield are NOT auto-absorbed here.
        // We follow Abracadabra MagicLP / DODO V2 reference behavior: the
        // first trade post-donation absorbs the imbalance via the curve's
        // natural regime math (e.g. ABOVE_ONE case 2.3 in sellBaseToken
        // returns `backToOneReceiveQuote + _ROne...`). To capture yield
        // into the equilibrium targets, call the public `sync()` endpoint
        // before swapping.

        address outputToken = params.zeroForOne ? TOKEN1 : TOKEN0;
        Currency inputCurrency  = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        // Tradable reserves = hot + Morpho-supplied − protocol-fee sleeve.
        // Treasury fees are accounted as off-curve liability; they must not
        // back swap liquidity, otherwise a later swap can drain past the
        // claimable balance and brick `claimProtocolFees`.
        uint256 baseReserveRaw  = _tradableAssets(TOKEN0);
        uint256 quoteReserveRaw = _tradableAssets(TOKEN1);
        uint256 hotOut          = IERC20(outputToken).balanceOf(address(this));
        uint256 effReserveOut   = params.zeroForOne ? quoteReserveRaw : baseReserveRaw;

        (uint256 canonicalMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (uint256 truncatedCanonicalMidE18,, uint16 dynamicSpreadBps) = _recordObservation(canonicalMidE18);

        (uint256 amountOut, uint256 feeOut) = _quote(
            amountIn,
            params.zeroForOne,
            baseReserveRaw,
            quoteReserveRaw,
            baseTargetE18,
            quoteTargetE18,
            truncatedCanonicalMidE18,
            dynamicSpreadBps,
            kBps
        );

        if (amountOut > effReserveOut) {
            revert InsufficientLiquidity(effReserveOut, amountOut);
        }

        // Accrue protocol's slice of the swap fee to the treasury sleeve.
        // The remaining (1 - protocolFeeBps) of `feeOut` stays in reserves
        // and accrues to LPs implicitly via pro-rata redemption.
        if (feeOut > 0 && protocolFeeBps > 0) {
            uint256 protoDelta = (feeOut * uint256(protocolFeeBps)) / 10_000;
            if (protoDelta > 0) {
                if (params.zeroForOne) {
                    protocolFee1 += protoDelta;
                    emit ProtocolFeeAccrued(TOKEN1, protoDelta, protocolFee1);
                } else {
                    protocolFee0 += protoDelta;
                    emit ProtocolFeeAccrued(TOKEN0, protoDelta, protocolFee0);
                }
            }
        }

        // JIT-withdraw from Morpho if TRADABLE hot reserve is insufficient.
        // Raw `hotOut` includes the accrued protocol-fee sleeve sitting in
        // the hot balance; paying swap output from those tokens would leave
        // `claimProtocolFees` depending on Morpho liquidity later. By gating
        // the withdraw decision on `hotOut − outputFee`, we preserve the fee
        // sleeve in hot and force a Morpho draw whenever the swap would
        // otherwise eat into it.
        uint256 outputFee = params.zeroForOne ? protocolFee1 : protocolFee0;
        uint256 hotOutTradable = hotOut > outputFee ? hotOut - outputFee : 0;
        if (amountOut > hotOutTradable) {
            _withdrawFromMorphoAssets(outputToken, amountOut - hotOutTradable);
        }

        inputCurrency.take(POOL_MANAGER, address(this), amountIn, false);
        outputCurrency.settle(POOL_MANAGER, address(this), amountOut, false);

        emit Swapped(
            msg.sender,
            inputCurrency,
            outputCurrency,
            amountIn,
            amountOut,
            truncatedCanonicalMidE18,
            params.zeroForOne ? baseReserveRaw : quoteReserveRaw,
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

    /// @notice Quote a DODO PMM swap using the vendored library
    ///         (`dodo-pmm/PMMPricing`), then apply the hook's spread/volatility
    ///         add-on as a separate LP-fee channel.
    /// @dev    All math runs in 1e18-normalized units; only the boundary
    ///         conversions touch raw token decimals. The PMM regime (R) is
    ///         derived from (B vs B0, Q vs Q0) inside `_buildPmmState`; the
    ///         adjusted target is recomputed per call to keep B0/Q0
    ///         consistent with current reserves at oracle mid `i`.
    function _quote(
        uint256 amountInRaw,
        bool    zeroForOne,
        uint256 baseReserveRaw,
        uint256 quoteReserveRaw,
        uint256 baseTarget_,
        uint256 quoteTarget_,
        uint256 canonicalMidE18,
        uint16  spreadOnTopBps,
        uint16  kBps_
    ) internal view returns (uint256 amountOutRaw, uint256 feeOutRaw) {
        uint8 inputDecimals = zeroForOne ? TOKEN0_DECIMALS : TOKEN1_DECIMALS;
        uint8 outputDecimals = zeroForOne ? TOKEN1_DECIMALS : TOKEN0_DECIMALS;

        uint256 amountInE18 = _rawToE18(amountInRaw, inputDecimals);
        if (amountInE18 == 0) return (0, 0);
        // Un-seeded pool: no curve to quote against.
        if (baseTarget_ == 0 || quoteTarget_ == 0) return (0, 0);

        PMMPricing.PMMState memory state = _buildPmmState(
            baseReserveRaw, quoteReserveRaw, baseTarget_, quoteTarget_, canonicalMidE18, kBps_
        );
        // Repair degenerate (donation / external-transfer) states before
        // handing to DODO math — its regime preconditions assume the state
        // is internally consistent.
        _normalizePmmState(state);
        PMMPricing.adjustedTarget(state);

        uint256 zeroSpreadOutE18;
        if (zeroForOne) {
            (zeroSpreadOutE18, ) = PMMPricing.sellBaseToken(state, amountInE18);
        } else {
            (zeroSpreadOutE18, ) = PMMPricing.sellQuoteToken(state, amountInE18);
        }

        // Layer spread on top — separable LP-fee channel feeding the
        // protocol-fee sleeve (Phase 2.7 #3). PMM curvature already accounts
        // for size impact.
        uint256 amountOutE18 = (zeroSpreadOutE18 * uint256(10_000 - spreadOnTopBps)) / 10_000;
        uint256 feeE18 = zeroSpreadOutE18 - amountOutE18;

        amountOutRaw = _e18ToRaw(amountOutE18, outputDecimals);
        feeOutRaw    = _e18ToRaw(feeE18, outputDecimals);
    }

    /// @notice Build the PMM state used for a single quote. Pure on inputs;
    ///         derives the regime R from (B, B0, Q, Q0). 1e18-normalized.
    function _buildPmmState(
        uint256 baseReserveRaw,
        uint256 quoteReserveRaw,
        uint256 baseTarget_,
        uint256 quoteTarget_,
        uint256 canonicalMidE18,
        uint16  kBps_
    ) internal view returns (PMMPricing.PMMState memory state) {
        uint256 B_e18 = _rawToE18(baseReserveRaw, TOKEN0_DECIMALS);
        uint256 Q_e18 = _rawToE18(quoteReserveRaw, TOKEN1_DECIMALS);

        // kBps ∈ [0, 1000] → K ∈ [0, 1e17], inside DODO's documented [0, 1e18]
        // range. kBps=10000 would saturate to K=1e18; we cap at MAX_K_BPS=1000.
        uint256 K = uint256(kBps_) * 1e14;

        state = PMMPricing.PMMState({
            i: canonicalMidE18,
            K: K,
            B: B_e18,
            Q: Q_e18,
            B0: baseTarget_,
            Q0: quoteTarget_,
            R: _regimeFor(B_e18, baseTarget_, Q_e18, quoteTarget_)
        });
    }

    /// @notice Classify current reserves against the equilibrium targets.
    ///         Mirrors DODO V2's regime semantics:
    ///           ABOVE_ONE: B < B0 AND Q > Q0 (sold base, price > i)
    ///           BELOW_ONE: B > B0 AND Q < Q0 (sold quote, price < i)
    ///           ONE:       at equilibrium
    /// @dev    Uses Q vs Q0 as the primary signal because it's robust to
    ///         B-side donations / external transfers. The B-side fallback
    ///         handles the symmetric Q-aligned case (Q == Q0, B drifted).
    ///         Degenerate combinations (B donation + Q donation) are repaired
    ///         in `_normalizePmmState` before PMMPricing math runs.
    function _regimeFor(uint256 B, uint256 B0, uint256 Q, uint256 Q0)
        internal
        pure
        returns (PMMPricing.RState)
    {
        if (B0 == 0 || Q0 == 0) return PMMPricing.RState.ONE; // un-seeded → no swaps quoted
        if (B == B0 && Q == Q0) return PMMPricing.RState.ONE;
        if (Q > Q0) return PMMPricing.RState.ABOVE_ONE;
        if (Q < Q0) return PMMPricing.RState.BELOW_ONE;
        // Q == Q0 but B != B0 → B-side drift. Classify by B direction.
        return B > B0 ? PMMPricing.RState.BELOW_ONE : PMMPricing.RState.ABOVE_ONE;
    }

    /// @notice Snap a possibly-degenerate PMM state into the regime's
    ///         expected reserve relationship. Without this, an attacker can
    ///         donate dust to the hook to drive (B, Q, B0, Q0) outside the
    ///         regime's preconditions and trigger an underflow inside the
    ///         vendored DODO math.
    /// @dev    Mutates `state.B0` / `state.Q0` in memory only — storage
    ///         targets are unchanged. Following DODO V2 / Abracadabra MagicLP
    ///         reference behavior, bilateral donations are NOT absorbed into
    ///         equilibrium here; the first trade post-donation reabsorbs the
    ///         imbalance via the curve's natural case-2.3 path. Call the
    ///         public `sync()` to capture yield/donations into targets.
    function _normalizePmmState(PMMPricing.PMMState memory state) internal pure {
        if (state.R == PMMPricing.RState.ABOVE_ONE) {
            // ABOVE_ONE precondition: B <= B0 AND Q >= Q0.
            if (state.B > state.B0) state.B0 = state.B;
            if (state.Q < state.Q0) state.Q0 = state.Q;
        } else if (state.R == PMMPricing.RState.BELOW_ONE) {
            // BELOW_ONE precondition: B >= B0 AND Q <= Q0.
            if (state.B < state.B0) state.B0 = state.B;
            if (state.Q > state.Q0) state.Q0 = state.Q;
        }
    }

    function quote(uint256 amountIn, bool zeroForOne) external view returns (uint256 amountOut) {
        uint256 baseReserveRaw  = _tradableAssets(TOKEN0);
        uint256 quoteReserveRaw = _tradableAssets(TOKEN1);
        (uint256 rawCanonicalMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (uint256 truncatedCanonicalMidE18,, uint16 dynamicSpreadBps) = _previewObservation(rawCanonicalMidE18);
        (amountOut, ) = _quote(
            amountIn,
            zeroForOne,
            baseReserveRaw,
            quoteReserveRaw,
            baseTargetE18,
            quoteTargetE18,
            truncatedCanonicalMidE18,
            dynamicSpreadBps,
            kBps
        );
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
        uint256 baseReserveRaw  = _tradableAssets(TOKEN0);
        uint256 quoteReserveRaw = _tradableAssets(TOKEN1);
        (uint256 rawCanonicalMidE18, ) = ORACLE.getMid(TOKEN0, TOKEN1);
        (uint256 truncatedCanonicalMidE18,, uint16 dynamicSpreadBps) = _previewObservation(rawCanonicalMidE18);
        oraclePriceE18 = zeroForOne ? truncatedCanonicalMidE18 : _invertE18(truncatedCanonicalMidE18);
        (buyAmount, ) = _quote(
            sellAmount,
            zeroForOne,
            baseReserveRaw,
            quoteReserveRaw,
            baseTargetE18,
            quoteTargetE18,
            truncatedCanonicalMidE18,
            dynamicSpreadBps,
            kBps
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

    /// @notice Total assets MINUS the accrued protocol-fee sleeve. This is
    ///         what's actually available to back swap quotes/output. Treasury
    ///         fees are accounted as liability and must not be drained by
    ///         later swaps; without this, `claimProtocolFees` could revert
    ///         on a previously-accrued balance.
    function _tradableAssets(address token) internal view returns (uint256 tradable) {
        uint256 total = _totalAssets(token);
        uint256 owed = token == TOKEN0 ? protocolFee0 : token == TOKEN1 ? protocolFee1 : 0;
        tradable = total > owed ? total - owed : 0;
    }

    /// @notice Public view exposing the tradable-assets snapshot used by the
    ///         swap path. Integrators preview `sync()` params by reading the
    ///         current tradable side, normalizing to 1e18, and passing as
    ///         `expectedBase/QuoteTargetE18`.
    function tradableAssets(address token) external view returns (uint256) {
        if (token != TOKEN0 && token != TOKEN1) revert InvalidToken(token);
        return _tradableAssets(token);
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
    /// @dev    Bypasses the protocol-fee sleeve guard — used by the treasury
    ///         claim path where dipping into the fee balance is the point.
    function _ensureHotBalance(address token, uint256 needed) internal {
        uint256 hot = IERC20(token).balanceOf(address(this));
        if (hot >= needed) return;
        _withdrawFromMorphoAssets(token, needed - hot);
    }

    /// @notice Pull `needed` of `token` into hot reserve, but never count the
    ///         protocol-fee sleeve toward "what's already there". Used by LP
    ///         redemption so that paying an LP doesn't consume fee tokens
    ///         and leave `claimProtocolFees` Morpho-dependent.
    function _ensureHotTradable(address token, uint256 needed) internal {
        uint256 hot = IERC20(token).balanceOf(address(this));
        uint256 fee = token == TOKEN0 ? protocolFee0 : token == TOKEN1 ? protocolFee1 : 0;
        uint256 hotTradable = hot > fee ? hot - fee : 0;
        if (hotTradable >= needed) return;
        _withdrawFromMorphoAssets(token, needed - hotTradable);
    }

    /// @notice Push hot excess of `loanToken` into Morpho supply. Skips
    ///         entirely when hotReservePct = 100% or when supplying 0.
    /// @dev    The protocol-fee sleeve is excluded from both the rebalance
    ///         calculus and the supply amount — fees must stay hot so
    ///         treasury claims do not depend on Morpho liquidity.
    function _rebalanceToken(address loanToken) internal {
        if (hotReservePct >= 10_000) return;
        uint256 hot = IERC20(loanToken).balanceOf(address(this));
        uint256 fee = loanToken == TOKEN0 ? protocolFee0 : loanToken == TOKEN1 ? protocolFee1 : 0;
        uint256 hotTradable = hot > fee ? hot - fee : 0;
        uint256 supplied = _morphoSupplyAssets(loanToken);
        uint256 tradableTotal = hotTradable + supplied;
        if (tradableTotal == 0) return;
        uint256 targetHot = (tradableTotal * uint256(hotReservePct)) / 10_000;
        if (hotTradable > targetHot) {
            _supplyToMorpho(loanToken, hotTradable - targetHot);
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
