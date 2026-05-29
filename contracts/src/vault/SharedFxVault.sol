// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@oz-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable} from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@oz-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";

import {IMorpho, MarketParams, Id, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";

import {ISharedFxVault} from "./interfaces/ISharedFxVault.sol";

/// @title  SharedFxVault
/// @notice A single shared reserve vault that JIT-backs swaps on otherwise-empty
///         Uniswap v4 FxSwapHook pools, replacing per-pool siloed reserves.
///
/// @dev    SECURITY MODEL (see docs/architecture/shared-fx-vault-spec.md, hardened via
///         /v4-security-foundations + /adversarial-uniswap-hooks + OZ /upgrade-solidity-contracts
///         + /develop-secure-contracts):
///
///         * SENIOR (lenders): deposit USDC → ERC-4626 shares. `totalAssets()` is PURE USDC
///           (hot + Morpho-supplied) — there is NO oracle in the share price, which deletes the
///           #1 threat (oracle→share-price manipulation). Senior USDC is supplied to Morpho Blue
///           (overcollateralized) and is NEVER used for fills in v1. Redeemable from Morpho liquidity.
///         * JUNIOR (protocol first-loss): a separate buffer (FX inventory + earmarked junior USDC)
///           funds every JIT fill and absorbs all market-making PnL. Funded via JUNIOR_ROLE.
///         * Fills come ONLY from junior. A swap can never reduce senior principal in v1.
///
///         Defenses baked in:
///         - HOOK_ROLE allowlist (explicit per-hook grant) — NOT Aqua0's "trust any ERC165 inheritor".
///         - per-swap + per-block notional caps (bounded, governable) — the load-bearing guard given
///           Arc has only ONE oracle (no Chainlink/RedStone); `maxOracleMoveBps` published for the hook
///           to enforce as a circuit breaker.
///         - balance-based inflow crediting — the hook is never trusted to self-report fill amounts.
///         - pause() kill switch (the hook owns swap-path pausing; this is the reserve-side switch).
///         - UUPS upgrades gated by UPGRADER_ROLE held by a TimelockController → no instant rug.
///         - ERC-7201 namespaced storage; `_disableInitializers()` in constructor; no selfdestruct,
///           no delegatecall, no `new`.
///         - SafeERC20 + forceApprove(exact)→implicit; decimals read per token. NB: Arc USDC (0x3600)
///           routes transfers through the 0x1800…0001 blocklist precompile — a liveness risk handled
///           by pause(), not an accounting risk.
contract SharedFxVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ISharedFxVault
{
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                  ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE"); // TimelockController
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE"); // bounded param tuning + pause
    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE"); // allowlisted FxSwapHooks
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE"); // Morpho rehypothecation
    bytes32 public constant JUNIOR_ROLE = keccak256("JUNIOR_ROLE"); // fund/withdraw junior buffer

    /*//////////////////////////////////////////////////////////////
                             PARAMETER BOUNDS
    //////////////////////////////////////////////////////////////*/
    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_PER_SWAP_BPS = 5_000; // ≤50% of junior USDC per swap
    uint16 internal constant MAX_PER_BLOCK_BPS = 10_000; // ≤100% per block
    uint16 internal constant MIN_ORACLE_MOVE_BPS = 10; // ≥0.10%
    uint16 internal constant MAX_ORACLE_MOVE_BPS = 1_000; // ≤10%

    /*//////////////////////////////////////////////////////////////
                          ERC-7201 NAMESPACED STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @custom:storage-location erc7201:bufx.sharedfxvault.main
    struct VaultStorage {
        IMorpho morpho;
        MarketParams morphoMarket; // senior USDC supply market (loanToken == USDC)
        uint256 morphoSupplied; // senior USDC principal supplied to Morpho (bookkeeping; NAV is live)
        uint256 seniorUsdcHot; // senior USDC held liquid (not in Morpho)
        uint256 juniorUsdc; // junior USDC buffer (funds USDC-out fills)
        mapping(address token => uint256 amount) juniorToken; // junior FX inventory
        address poolManager; // canonical v4 PoolManager — fills may only route here
        address oracle; // FxOracle — vault prices FX-out notional itself (never trusts the hook)
        uint16 hotReservePctBps; // target hot USDC vs Morpho
        uint16 perSwapCapBps; // max single fill notional vs junior USDC
        uint16 perBlockCapBps; // max per-block notional vs junior USDC
        uint16 maxOracleMoveBps; // circuit-breaker hint for the hook
        uint256 capBlock; // LEGACY (global) block of current per-block window — unused after per-hook migration
        uint256 capBlockFilled; // LEGACY (global) usdc notional filled in current block — unused after per-hook migration
        uint256 capBaseJuniorUsdc; // LEGACY (global) junior USDC snapshot at window start — unused after per-hook migration
        // --- APPENDED (Codex HIGH#1): per-hook junior accounting -------------------------------
        // UUPS storage-compat: NEW fields appended at the END of the struct; existing fields above
        // are neither reordered nor removed. `juniorUsdc`/`juniorToken` and the three `cap*` scalars
        // become LEGACY/unused after migrateLegacyJuniorToHook moves their value into a hook slice.
        mapping(address hook => uint256 amount) hookJuniorUsdc; // per-hook junior USDC slice
        mapping(address hook => mapping(address token => uint256 amount)) hookJuniorToken; // per-hook FX inventory
        uint256 totalJuniorUsdc; // == sum of hookJuniorUsdc (for O(1) balance-based inflow)
        mapping(address token => uint256 amount) totalJuniorToken; // == sum over hooks of hookJuniorToken[*][token]
        // per-hook cap windows (replace the global cap* scalars)
        mapping(address hook => uint256 block_) capBlockOf; // block of hook's current per-block window
        mapping(address hook => uint256 filled) capBlockFilledOf; // usdc notional filled this block (per hook)
        mapping(address hook => uint256 base) capBaseJuniorUsdcOf; // hook's junior USDC snapshot at window start
        bool legacyJuniorMigrated; // one-shot guard for migrateLegacyJuniorToHook
    }

    // keccak256(abi.encode(uint256(keccak256("bufx.sharedfxvault.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x82dfe0b48341232b6b6f25f0ced28120c66a25ed3cb1d8e79e3155dc48a95300;

    function _s() private pure returns (VaultStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/
    error ZeroAddress();
    error MorphoLoanTokenMismatch();
    error PerSwapCapExceeded();
    error PerBlockCapExceeded();
    error JuniorUsdcShort();
    error FxInventoryShort();
    error InsufficientSeniorLiquidity();
    error ParamOutOfBounds();
    error BalanceUnderflow();
    error PoolManagerMismatch();
    error LegacyAlreadyMigrated();
    error LegacyNotMigrated();
    error HookNotAllowlisted();

    /*//////////////////////////////////////////////////////////////
                          EVENTS (per-hook migration)
    //////////////////////////////////////////////////////////////*/
    event LegacyJuniorMigrated(address indexed hook, uint256 usdc, address[] tokens);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/
    function initialize(
        IERC20 usdc,
        address admin,
        address timelock,
        address poolManager,
        address oracle,
        IMorpho morpho_,
        MarketParams calldata morphoMarket_
    ) external initializer {
        __ERC20_init("BUFX Shared FX Vault USDC", "bufxUSDC");
        __ERC4626_init(usdc);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (
            admin == address(0) || timelock == address(0) || poolManager == address(0)
                || oracle == address(0) || address(morpho_) == address(0)
        ) revert ZeroAddress();
        if (morphoMarket_.loanToken != address(usdc)) revert MorphoLoanTokenMismatch();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, timelock); // upgrades are timelocked → no instant rug
        // CRITICAL: make UPGRADER_ROLE its own admin so DEFAULT_ADMIN (admin) can NOT
        // self-grant upgrade rights and bypass the timelock. Only the timelock controls upgrades.
        _setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE);

        VaultStorage storage $ = _s();
        $.morpho = morpho_;
        $.morphoMarket = morphoMarket_;
        $.poolManager = poolManager;
        $.oracle = oracle;
        $.hotReservePctBps = 2_000; // 20% hot, 80% Morpho
        $.perSwapCapBps = 2_000; // 20% of junior USDC per swap
        $.perBlockCapBps = 5_000; // 50% per block
        $.maxOracleMoveBps = 200; // 2%
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                          ERC-4626 (SENIOR, USDC)
    //////////////////////////////////////////////////////////////*/

    /// @dev Pure-USDC NAV: hot senior USDC + live Morpho supply assets. No oracle.
    ///      Morpho assets are read from the position + market getters (reflects interest
    ///      realized as of the market's last touch — far better than principal-only).
    ///      HARDENING (pre-P5, before public deposits): also accrue on the value-bearing
    ///      path (deposit/withdraw) so entry/exit pricing is exact, or use the extSloads-based
    ///      MorphoBalancesLib simulation. FX inventory and junior USDC are NOT senior assets.
    function totalAssets() public view override returns (uint256) {
        return _s().seniorUsdcHot + _morphoSupplyAssets();
    }

    /// @dev Diamond-resolution override: both ERC4626Upgradeable and ISharedFxVault
    ///      declare `asset()`. Forwards to the ERC4626 implementation unchanged.
    function asset() public view override(ERC4626Upgradeable, ISharedFxVault) returns (address) {
        return super.asset();
    }

    function _morphoSupplyAssets() internal view returns (uint256) {
        VaultStorage storage $ = _s();
        Id id = $.morphoMarket.id();
        Market memory m = $.morpho.market(id);
        uint256 shares = $.morpho.position(id, address(this)).supplyShares;
        return shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        super._deposit(caller, receiver, assets, shares); // pulls USDC, mints shares
        _s().seniorUsdcHot += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        VaultStorage storage $ = _s();
        if ($.seniorUsdcHot < assets) {
            _withdrawFromMorpho(assets - $.seniorUsdcHot); // top up hot from Morpho liquidity
        }
        if ($.seniorUsdcHot < assets) revert InsufficientSeniorLiquidity();
        $.seniorUsdcHot -= assets;
        super._withdraw(caller, receiver, owner, assets, shares); // burns shares, sends USDC
    }

    /*//////////////////////////////////////////////////////////////
                       HOOK FILL SURFACE (JUNIOR ONLY)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISharedFxVault
    function fundFill(address outToken, uint256 outAmount, address poolManager)
        external
        override
        onlyRole(HOOK_ROLE)
        whenNotPaused
        nonReentrant
    {
        VaultStorage storage $ = _s();
        // Funds may ONLY route to the canonical v4 PoolManager — a malicious-but-allowlisted
        // hook cannot redirect junior funds to itself.
        if (poolManager != $.poolManager) revert PoolManagerMismatch();

        // The vault prices the USDC notional ITSELF — never trusts a hook-supplied number.
        // USDC-out: the USDC leaving IS the notional. FX-out: oracle-priced (reverts if stale).
        uint256 usdcNotional = _usdcNotional(outToken, outAmount);
        // Caps + debit are keyed by the CALLING HOOK (msg.sender): one pool's junior slice
        // can never be drained to fund another pool (Codex HIGH#1).
        _checkAndAccrueCaps(msg.sender, usdcNotional);

        if (outToken == asset()) {
            if ($.hookJuniorUsdc[msg.sender] < outAmount) revert JuniorUsdcShort();
            $.hookJuniorUsdc[msg.sender] -= outAmount;
            $.totalJuniorUsdc -= outAmount; // global total stays = sum of per-hook slices
        } else {
            if ($.hookJuniorToken[msg.sender][outToken] < outAmount) revert FxInventoryShort();
            $.hookJuniorToken[msg.sender][outToken] -= outAmount;
            $.totalJuniorToken[outToken] -= outAmount;
        }
        IERC20(outToken).safeTransfer(poolManager, outAmount);
        emit FillFunded(msg.sender, outToken, outAmount, usdcNotional);
    }

    /// @dev USDC-equivalent notional of an output leg. USDC-out → the amount itself.
    ///      FX-out → oracle mid (USDC per token) at the token's decimals, normalized to
    ///      USDC decimals. Reverts if the oracle is stale (same gate the hook hit pricing
    ///      the swap), so a fill can never be sized against a stale price.
    function _usdcNotional(address outToken, uint256 outAmount) internal view returns (uint256) {
        address usdc = asset();
        if (outToken == usdc) return outAmount;
        (uint256 midE18,) = IFxOracle(_s().oracle).getMid(outToken, usdc); // USDC per outToken, 1e18
        uint256 dOut = IERC20Metadata(outToken).decimals();
        uint256 dUsdc = IERC20Metadata(usdc).decimals();
        // valueE18 = (outAmount scaled to 1e18) * mid / 1e18; then down to USDC decimals.
        uint256 valueE18 = (outAmount * (10 ** (18 - dOut))) * midE18 / 1e18;
        return valueE18 / (10 ** (18 - dUsdc));
    }

    /// @inheritdoc ISharedFxVault
    /// @dev Balance-based: credits the real measured delta, never a hook-reported number.
    ///      Senior USDC only enters via `_deposit` (tracked), so any untracked balance is fill input.
    function recordInflow(address inToken)
        external
        override
        onlyRole(HOOK_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 credited)
    {
        VaultStorage storage $ = _s();
        // Legacy guard: while a pre-upgrade GLOBAL junior balance for this token is unmigrated it is
        // "unaccounted" (totals are 0), so a hook could sweep it here. Block until migrated to a slice.
        if ((inToken == asset() ? $.juniorUsdc : $.juniorToken[inToken]) != 0) revert LegacyNotMigrated();
        uint256 bal = IERC20(inToken).balanceOf(address(this));
        // O(1) balance-based: subtract senior (USDC only) + the GLOBAL junior total. The newly
        // measured delta is credited to the CALLING HOOK's slice (and the matching global total).
        uint256 accounted =
            inToken == asset() ? ($.seniorUsdcHot + $.totalJuniorUsdc) : $.totalJuniorToken[inToken];
        if (bal < accounted) revert BalanceUnderflow();
        credited = bal - accounted;
        if (credited == 0) return 0;
        if (inToken == asset()) {
            _initCapWindow(msg.sender); // snapshot cap base BEFORE this credit lands
            $.hookJuniorUsdc[msg.sender] += credited;
            $.totalJuniorUsdc += credited;
        } else {
            $.hookJuniorToken[msg.sender][inToken] += credited;
            $.totalJuniorToken[inToken] += credited;
        }
        emit InflowRecorded(msg.sender, inToken, credited);
    }

    /// @dev Snapshot the per-hook cap denominator at the START of each block, BEFORE any same-block
    ///      credit. Called from fundFill, recordInflow, and fundJunior so a hook can't pre-credit its
    ///      USDC slice (via recordInflow/fundJunior) and then widen its own per-swap/per-block caps.
    function _initCapWindow(address hook) internal {
        VaultStorage storage $ = _s();
        if ($.capBlockOf[hook] != block.number) {
            $.capBlockOf[hook] = block.number;
            $.capBlockFilledOf[hook] = 0;
            $.capBaseJuniorUsdcOf[hook] = $.hookJuniorUsdc[hook]; // pre-credit snapshot
        }
    }

    function _checkAndAccrueCaps(address hook, uint256 usdcNotional) internal {
        VaultStorage storage $ = _s();
        _initCapWindow(hook);
        uint256 base = $.capBaseJuniorUsdcOf[hook];
        if (usdcNotional > (base * $.perSwapCapBps) / BPS) revert PerSwapCapExceeded();
        uint256 filled = $.capBlockFilledOf[hook] + usdcNotional;
        if (filled > (base * $.perBlockCapBps) / BPS) revert PerBlockCapExceeded();
        $.capBlockFilledOf[hook] = filled;
    }

    /*//////////////////////////////////////////////////////////////
                          JUNIOR BUFFER (PROTOCOL)
    //////////////////////////////////////////////////////////////*/
    /// @notice Fund a SPECIFIC hook's junior slice (per-pool first-loss). Allocates the funded
    ///         amount to `hook`'s slice AND the matching global total.
    function fundJunior(address hook, address token, uint256 amount)
        external
        onlyRole(JUNIOR_ROLE)
        nonReentrant
    {
        if (hook == address(0)) revert ZeroAddress();
        // Credit the REAL received delta, not the requested amount — robust to any
        // fee-on-transfer / non-exact ERC20 behavior (USDC is exact today; defense-in-depth).
        VaultStorage storage $ = _s();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        // NB: fundJunior is JUNIOR_ROLE (trusted, setup-time) and legitimately grows the cap base —
        // do NOT pre-snapshot here. Only recordInflow (hook-callable) is barred from widening caps.
        if (token == asset()) {
            $.hookJuniorUsdc[hook] += received;
            $.totalJuniorUsdc += received;
        } else {
            $.hookJuniorToken[hook][token] += received;
            $.totalJuniorToken[token] += received;
        }
        emit JuniorFunded(token, received);
    }

    /// @notice Withdraw from a SPECIFIC hook's junior slice. Debits `hook`'s slice AND the
    ///         matching global total.
    function withdrawJunior(address hook, address token, uint256 amount, address to)
        external
        onlyRole(JUNIOR_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        VaultStorage storage $ = _s();
        if (token == asset()) {
            if ($.hookJuniorUsdc[hook] < amount) revert JuniorUsdcShort();
            $.hookJuniorUsdc[hook] -= amount;
            $.totalJuniorUsdc -= amount;
        } else {
            if ($.hookJuniorToken[hook][token] < amount) revert FxInventoryShort();
            $.hookJuniorToken[hook][token] -= amount;
            $.totalJuniorToken[token] -= amount;
        }
        IERC20(token).safeTransfer(to, amount);
        emit JuniorWithdrawn(token, amount, to);
    }

    /// @notice ONE-TIME migration of the pre-allocation deployment's GLOBAL junior buffer
    ///         (`juniorUsdc` + `juniorToken[token]`) into `hook`'s per-hook slice + global totals,
    ///         then zeroes the legacy globals. For the deployed vault's EURC junior
    ///         (10,100 USDC + 9,090 EURC) → the EURC hook's slice. Guarded so it runs at most once.
    function migrateLegacyJuniorToHook(address hook, address[] calldata tokens)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (hook == address(0)) revert ZeroAddress();
        // Only an allowlisted hook can receive the migrated slice (a typo'd hook can't strand funds
        // in a dead slice that a non-hook could never spend). Idempotent: re-callable to move any
        // legacy balance a prior call omitted — moving a zero is a no-op. The recordInflow legacy
        // guard independently blocks sweeping any legacy this hasn't moved yet.
        if (!hasRole(HOOK_ROLE, hook)) revert HookNotAllowlisted();
        VaultStorage storage $ = _s();

        uint256 legacyUsdc = $.juniorUsdc;
        if (legacyUsdc != 0) {
            $.juniorUsdc = 0;
            $.hookJuniorUsdc[hook] += legacyUsdc;
            $.totalJuniorUsdc += legacyUsdc;
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 legacyTok = $.juniorToken[token];
            if (legacyTok != 0) {
                $.juniorToken[token] = 0;
                $.hookJuniorToken[hook][token] += legacyTok;
                $.totalJuniorToken[token] += legacyTok;
            }
        }
        emit LegacyJuniorMigrated(hook, legacyUsdc, tokens);
    }

    /*//////////////////////////////////////////////////////////////
                       MORPHO REHYPOTHECATION (SENIOR)
    //////////////////////////////////////////////////////////////*/
    function supplyIdleToMorpho(uint256 assets) external onlyRole(KEEPER_ROLE) nonReentrant {
        VaultStorage storage $ = _s();
        if ($.seniorUsdcHot < assets) revert InsufficientSeniorLiquidity();
        $.seniorUsdcHot -= assets;
        $.morphoSupplied += assets;
        IERC20(asset()).forceApprove(address($.morpho), assets);
        $.morpho.supply($.morphoMarket, assets, 0, address(this), "");
        emit MorphoSupplied(assets);
    }

    function withdrawFromMorpho(uint256 assets) external onlyRole(KEEPER_ROLE) nonReentrant {
        _withdrawFromMorpho(assets);
    }

    /// @dev Withdraws `assets` principal from Morpho; any accrued interest above principal
    ///      lands in `seniorUsdcHot`, realizing yield into senior NAV.
    function _withdrawFromMorpho(uint256 assets) internal {
        VaultStorage storage $ = _s();
        (uint256 withdrawn,) = $.morpho.withdraw($.morphoMarket, assets, 0, address(this), address(this));
        $.morphoSupplied = $.morphoSupplied > assets ? $.morphoSupplied - assets : 0;
        $.seniorUsdcHot += withdrawn;
        emit MorphoWithdrawn(withdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE (BOUNDED, TIMELOCKED)
    //////////////////////////////////////////////////////////////*/
    function setCaps(uint16 perSwapBps, uint16 perBlockBps, uint16 maxMoveBps) external onlyRole(GOVERNOR_ROLE) {
        if (perSwapBps > MAX_PER_SWAP_BPS || perBlockBps > MAX_PER_BLOCK_BPS) revert ParamOutOfBounds();
        if (maxMoveBps < MIN_ORACLE_MOVE_BPS || maxMoveBps > MAX_ORACLE_MOVE_BPS) revert ParamOutOfBounds();
        VaultStorage storage $ = _s();
        $.perSwapCapBps = perSwapBps;
        $.perBlockCapBps = perBlockBps;
        $.maxOracleMoveBps = maxMoveBps;
        emit CapsUpdated(perSwapBps, perBlockBps, maxMoveBps);
    }

    function setHotReservePct(uint16 bps) external onlyRole(GOVERNOR_ROLE) {
        if (bps > BPS) revert ParamOutOfBounds();
        _s().hotReservePctBps = bps;
        emit HotReserveUpdated(bps);
    }

    function setPoolManager(address poolManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (poolManager == address(0)) revert ZeroAddress();
        _s().poolManager = poolManager;
    }

    function setOracle(address oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle == address(0)) revert ZeroAddress();
        _s().oracle = oracle;
    }

    function allowHook(address hook, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hook == address(0)) revert ZeroAddress();
        if (allowed) {
            _grantRole(HOOK_ROLE, hook);
        } else {
            _revokeRole(HOOK_ROLE, hook);
        }
        emit HookAllowed(hook, allowed);
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/
    /// @inheritdoc ISharedFxVault
    /// @dev Keyed on msg.sender so the calling hook's `_vaultReserve` reads ITS OWN slice
    ///      (interface signature unchanged).
    function juniorUsdc() external view override returns (uint256) {
        return _s().hookJuniorUsdc[msg.sender];
    }

    /// @inheritdoc ISharedFxVault
    function juniorTokenBalance(address token) external view override returns (uint256) {
        return _s().hookJuniorToken[msg.sender][token];
    }

    /// @notice Explicit-query: a specific hook's junior USDC slice.
    function juniorUsdcOf(address hook) external view returns (uint256) {
        return _s().hookJuniorUsdc[hook];
    }

    /// @notice Explicit-query: a specific hook's junior FX inventory of `token`.
    function juniorTokenBalanceOf(address hook, address token) external view returns (uint256) {
        return _s().hookJuniorToken[hook][token];
    }

    /// @notice Global junior USDC total (= sum over hooks).
    function totalJuniorUsdc() external view returns (uint256) {
        return _s().totalJuniorUsdc;
    }

    /// @notice Global junior FX-token total of `token` (= sum over hooks).
    function totalJuniorTokenBalance(address token) external view returns (uint256) {
        return _s().totalJuniorToken[token];
    }

    function isAllowedHook(address hook) external view override returns (bool) {
        return hasRole(HOOK_ROLE, hook);
    }

    function maxOracleMoveBps() external view returns (uint16) {
        return _s().maxOracleMoveBps;
    }

    function caps() external view returns (uint16 perSwapBps, uint16 perBlockBps, uint16 maxMoveBps) {
        VaultStorage storage $ = _s();
        return ($.perSwapCapBps, $.perBlockCapBps, $.maxOracleMoveBps);
    }

    function morphoSupplied() external view returns (uint256) {
        return _s().morphoSupplied;
    }

    function seniorUsdcHot() external view returns (uint256) {
        return _s().seniorUsdcHot;
    }

    function poolManager() external view returns (address) {
        return _s().poolManager;
    }

    function oracle() external view returns (address) {
        return _s().oracle;
    }

    /// @notice The USDC notional the vault would book for an output leg (oracle-priced for FX-out).
    function quoteUsdcNotional(address outToken, uint256 outAmount) external view returns (uint256) {
        return _usdcNotional(outToken, outAmount);
    }

    /// @notice Live senior USDC supplied to Morpho (NAV component).
    function morphoLiveAssets() external view returns (uint256) {
        return _morphoSupplyAssets();
    }
}
