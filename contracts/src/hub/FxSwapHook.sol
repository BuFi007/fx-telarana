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

import {IMorpho, MarketParams as MorphoMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
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
///
/// ## Permission bits
///
/// `beforeAddLiquidity` + `beforeRemoveLiquidity` REVERT — all LP flow
/// must go through `deposit`/`redeem`. `beforeSwap` + `afterSwap` +
/// `beforeSwapReturnDelta` enable the PMM. Mine the deploy address with
/// `HookMiner` so the low-order bits match `getHookPermissions`.
contract FxSwapHook is IHooks, ReentrancyGuard {
    using SafeERC20 for IERC20;
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

    /*//////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    /// @notice PMM knobs (see _quote).
    uint16 public spreadBps;
    uint16 public kBps;

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
    error HookNotEnabled(bytes4 hook);
    error PoolKeyMismatch();
    error InsufficientLiquidity(uint256 effectiveReserveOut, uint256 amountOutRequested);
    error InsufficientShares(uint256 requested, uint256 available);
    error ZeroAmount();
    error TokensNotSorted();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SpreadSet(uint16 oldBps, uint16 newBps);
    event KSet(uint16 oldBps, uint16 newBps);
    event HotReservePctSet(uint16 oldBps, uint16 newBps);
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
        spreadBps     = DEFAULT_SPREAD_BPS;
        kBps          = DEFAULT_K_BPS;
        hotReservePct = DEFAULT_HOT_RESERVE_PCT;
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

        (uint256 midE18, ) = ORACLE.getMid(inputToken, outputToken);
        uint256 amountOut  = _quote(amountIn, effReserveIn, effReserveOut, midE18, spreadBps, kBps);

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
            int128(int256(amountIn)),
            -int128(int256(amountOut))
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
        uint16  k
    ) internal pure returns (uint256 amountOut) {
        uint256 spreadAdj = uint256(10_000 - spread);
        uint256 baseOut = (amountIn * midE18 * spreadAdj) / 1e18 / 10_000;

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
        (uint256 midE18, )  = ORACLE.getMid(inputToken, outputToken);
        return _quote(amountIn, reserveIn, reserveOut, midE18, spreadBps, kBps);
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
