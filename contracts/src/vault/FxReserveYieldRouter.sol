// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@oz-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorpho, MarketParams, Id, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";

import {IUsycTeller} from "./interfaces/IUsycTeller.sol";

/// @title  FxReserveYieldRouter — P1 (USYC) + P2 (Morpho sinks), tier-gated
/// @notice Makes idle protocol/institutional capital productive across multiple on-chain sinks, the
///         yield engine of "The Yield Machine" (docs/architecture/yield-machine-spec.md):
///           * USDC → USYC (Circle Teller, atomic T+0 T-bill floor) and/or Morpho USDC-loan market.
///           * FX inventory (EURC/MXNB/QCAD/AUDF/cirBTC…) → Morpho FX-loan markets — the ONLY on-chain
///             yield path for non-USD inventory (USYC is USD-only).
///         A permissionless `rebalance()` / `rebalanceFx()` (on-chain (s,S) guard = the trigger) keeps
///         each asset's liquid buffer topped and the excess earning. No off-chain SaaS orchestrator.
///
/// @dev    THE TWO HARD INVARIANTS:
///         1. PERFORMANCE LAW — the swap hot path never touches yield/Gateway. Upheld by construction:
///            standalone contract, ZERO edit to SharedFxVault, no swap callback reaches it.
///         2. COMPLIANCE LAW — retail NAV never touches USYC (Reg-S). Structural: `Tier.RETAIL` can
///            never be funded here, and the router is not referenced by the senior ERC-4626 NAV, so
///            USYC never enters the contract that prices retail shares. Note: within this non-retail
///            router, USDC may route to USYC OR Morpho freely — the wall is "no retail capital here",
///            already guaranteed. Retail's own Morpho yield lives in SharedFxVault's par-pure senior
///            path, untouched by this router.
///
///         The router stays ORACLE-FREE: USDC NAV is pure-USD (liquid + USYC NAV + Morpho live USDC);
///         FX positions are accounted in NATIVE token terms (you earn more EURC, more MXNB…), never
///         marked to a USDC oracle. Mirrors SharedFxVault's hardening: UUPS gated by a self-administered
///         UPGRADER_ROLE (timelock), ERC-7201 storage, _disableInitializers, SafeERC20 + forceApprove,
///         pausable, nonReentrant value paths, balance-based crediting. Morpho integration mirrors
///         SharedFxVault.supplyIdleToMorpho / _morphoSupplyAssets exactly (live NAV from the getters).
contract FxReserveYieldRouter is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /// @notice Compliance tier of USDC capital. RETAIL exists only to make the wall explicit and
    ///         testable — any RETAIL op reverts; retail capital can never reach this router.
    enum Tier {
        RETAIL,
        INSTITUTIONAL,
        PROTOCOL
    }

    /*//////////////////////////////////////////////////////////////
                                  ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE"); // TimelockController
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE"); // watermarks/targets + pause
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE"); // move principal in/out (treasury ops)
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE"); // manual deploy/redeem overrides

    uint16 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                          ERC-7201 NAMESPACED STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @dev Per-FX-token config + accounting. FX is non-retail by nature (junior/protocol inventory),
    ///      so no Tier split — a single principal in native token units.
    struct FxAsset {
        bool managed;
        bool morphoEnabled;
        MarketParams morphoMarket; // loanToken == the FX token, USDC collateral
        uint256 principal; // cost basis, native token units
        uint256 lowWaterToken; // (s) keep liquid
        uint256 highWaterToken; // (S) supply excess to Morpho
    }

    /// @custom:storage-location erc7201:bufx.fxreserveyieldrouter.main
    struct RouterStorage {
        // --- P1: USDC + USYC ---
        IERC20 usdc; // Arc native USDC 0x3600…0000
        IERC20 usyc; // 6 dec
        IUsycTeller teller; // USYC Teller
        mapping(Tier tier => uint256 principalUsdc) principal; // USDC cost basis per tier (RETAIL == 0)
        uint256 lowWaterUsdc; // (s)
        uint256 highWaterUsdc; // (S)
        // --- P2: Morpho sinks (appended) ---
        IMorpho morpho; // Morpho Blue (address(0) ⇒ Morpho sinks disabled)
        MarketParams usdcMorphoMarket; // USDC-loan market (loanToken == usdc)
        bool usdcMorphoEnabled;
        uint16 usdcMorphoTargetBps; // of DEPLOYABLE USDC, share routed to Morpho (rest → USYC)
        mapping(address token => FxAsset) fxAsset;
        address[] fxTokenList;
    }

    // keccak256(abi.encode(uint256(keccak256("bufx.fxreserveyieldrouter.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x0b2414d333685b566042fad5a18f380a4de25502cb083b6829bb70fea3e59f00;

    function _s() private pure returns (RouterStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/
    error ZeroAddress();
    error RetailForbidden();
    error TierPrincipalShort();
    error BadWaterMarks();
    error RebalanceNoOp();
    error InsufficientLiquidity();
    error TellerHasPosition();
    error TellerAssetMismatch();
    error YieldShort();
    error ParamOutOfBounds();
    error MorphoNotSet();
    error MarketLoanTokenMismatch();
    error FxNotManaged();
    error NotAnFxToken();

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/
    event Funded(Tier indexed tier, uint256 amount);
    event Defunded(Tier indexed tier, uint256 amount, address indexed to);
    event DeployedToYield(uint256 usdcIn, uint256 usycOut);
    event RedeemedFromYield(uint256 usycIn, uint256 usdcOut);
    event YieldHarvested(address indexed to, uint256 amount);
    event WaterMarksUpdated(uint256 lowWaterUsdc, uint256 highWaterUsdc);
    event TellerUpdated(address indexed teller);
    // P2
    event MorphoUpdated(address indexed morpho);
    event UsdcMorphoMarketSet(bool enabled, uint16 targetBps);
    event UsdcSuppliedToMorpho(uint256 assets);
    event UsdcWithdrawnFromMorpho(uint256 assets);
    event FxMarketSet(address indexed token, uint256 lowWater, uint256 highWater);
    event FxFunded(address indexed token, uint256 amount);
    event FxDefunded(address indexed token, uint256 amount, address indexed to);
    event FxSuppliedToMorpho(address indexed token, uint256 amount);
    event FxWithdrawnFromMorpho(address indexed token, uint256 amount);
    event FxYieldHarvested(address indexed token, address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/
    function initialize(
        IERC20 usdc_,
        IERC20 usyc_,
        IUsycTeller teller_,
        address admin,
        address timelock,
        uint256 lowWaterUsdc_,
        uint256 highWaterUsdc_
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (
            address(usdc_) == address(0) || address(usyc_) == address(0) || address(teller_) == address(0)
                || admin == address(0) || timelock == address(0)
        ) revert ZeroAddress();
        if (highWaterUsdc_ < lowWaterUsdc_) revert BadWaterMarks();
        if (teller_.asset() != address(usdc_)) revert TellerAssetMismatch();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, timelock);
        _setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE); // DEFAULT_ADMIN can't self-grant the upgrade key

        RouterStorage storage $ = _s();
        $.usdc = usdc_;
        $.usyc = usyc_;
        $.teller = teller_;
        $.lowWaterUsdc = lowWaterUsdc_;
        $.highWaterUsdc = highWaterUsdc_;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                  USDC PRINCIPAL IN / OUT (TREASURY OPS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Fund the router with `amount` USDC attributed to `tier`. RETAIL reverts (compliance law).
    function depositFor(Tier tier, uint256 amount) external onlyRole(FUNDER_ROLE) whenNotPaused nonReentrant {
        if (tier == Tier.RETAIL) revert RetailForbidden();
        RouterStorage storage $ = _s();
        uint256 before = $.usdc.balanceOf(address(this));
        $.usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = $.usdc.balanceOf(address(this)) - before;
        $.principal[tier] += received;
        emit Funded(tier, received);
    }

    /// @notice Return up to `tier`'s USDC principal to `to` (pulling from Morpho/USYC if short).
    function withdrawFor(Tier tier, uint256 amount, address to) external onlyRole(FUNDER_ROLE) nonReentrant {
        if (tier == Tier.RETAIL) revert RetailForbidden();
        if (to == address(0)) revert ZeroAddress();
        RouterStorage storage $ = _s();
        if ($.principal[tier] < amount) revert TierPrincipalShort();
        _ensureLiquidUsdc(amount);
        $.principal[tier] -= amount;
        $.usdc.safeTransfer(to, amount);
        emit Defunded(tier, amount, to);
    }

    /// @notice Send accrued USDC yield (value above total USDC principal) to `to`. Never principal.
    function harvestYield(address to, uint256 amount) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > accruedYieldUsdc()) revert YieldShort();
        _ensureLiquidUsdc(amount);
        _s().usdc.safeTransfer(to, amount);
        emit YieldHarvested(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                  USDC REBALANCE — on-chain (s,S), permissionless
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless: deploy excess liquid USDC across sinks (Morpho per target%, rest USYC),
    ///         or pull from sinks to refill the buffer, per the (s,S) watermarks.
    function rebalance() external whenNotPaused nonReentrant {
        RouterStorage storage $ = _s();
        uint256 liquid = $.usdc.balanceOf(address(this));
        if (liquid > $.highWaterUsdc) {
            _deployUsdc(liquid - $.highWaterUsdc);
        } else if (liquid < $.lowWaterUsdc) {
            _refillUsdc($.lowWaterUsdc - liquid);
        } else {
            revert RebalanceNoOp();
        }
    }

    /// @notice Manual override: subscribe `amount` USDC into USYC. KEEPER only.
    function deployToYield(uint256 amount) external onlyRole(KEEPER_ROLE) whenNotPaused nonReentrant {
        _deployToYield(amount);
    }

    /// @notice Manual override: redeem USYC to recover up to `usdcWanted`. KEEPER only.
    function redeemFromYield(uint256 usdcWanted) external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256) {
        return _redeemFromYield(usdcWanted);
    }

    function _deployUsdc(uint256 amount) internal {
        RouterStorage storage $ = _s();
        uint256 morphoPart;
        if ($.usdcMorphoEnabled && address($.morpho) != address(0)) {
            morphoPart = (amount * $.usdcMorphoTargetBps) / BPS;
        }
        uint256 usycPart = amount - morphoPart;
        if (morphoPart > 0) {
            _morphoSupply($.usdcMorphoMarket, morphoPart);
            emit UsdcSuppliedToMorpho(morphoPart);
        }
        if (usycPart > 0) _deployToYield(usycPart);
    }

    /// @dev Refill the USDC buffer by `need`: pull from Morpho first (par USD), then USYC.
    function _refillUsdc(uint256 need) internal {
        RouterStorage storage $ = _s();
        if ($.usdcMorphoEnabled && address($.morpho) != address(0)) {
            uint256 live = _morphoLiveAssets($.usdcMorphoMarket);
            uint256 pull = need < live ? need : live;
            if (pull > 0) {
                uint256 w = _morphoWithdraw($.usdcMorphoMarket, pull);
                emit UsdcWithdrawnFromMorpho(w);
                need = need > w ? need - w : 0;
            }
        }
        if (need > 0) _redeemFromYield(need);
    }

    function _deployToYield(uint256 amount) internal {
        RouterStorage storage $ = _s();
        if (amount == 0) revert RebalanceNoOp();
        if ($.usdc.balanceOf(address(this)) < amount) revert InsufficientLiquidity();
        $.usdc.forceApprove(address($.teller), amount);
        uint256 usycOut = $.teller.deposit(amount, address(this));
        emit DeployedToYield(amount, usycOut);
    }

    function _redeemFromYield(uint256 usdcWanted) internal returns (uint256 usdcOut) {
        RouterStorage storage $ = _s();
        if (usdcWanted == 0) return 0;
        uint256 held = $.usyc.balanceOf(address(this));
        if (held == 0) return 0;
        uint256 shares;
        if (usdcWanted >= $.teller.previewRedeem(held)) {
            shares = held; // target ≥ whole position → redeem all (no previewWithdraw overflow)
        } else {
            shares = $.teller.previewWithdraw(usdcWanted);
            if (shares > held) shares = held;
        }
        if (shares == 0) return 0;
        $.usyc.forceApprove(address($.teller), shares);
        usdcOut = $.teller.redeem(shares, address(this), address(this));
        emit RedeemedFromYield(shares, usdcOut);
    }

    /// @dev Ensure ≥ `amount` liquid USDC, pulling from Morpho then USYC if short.
    function _ensureLiquidUsdc(uint256 amount) internal {
        RouterStorage storage $ = _s();
        uint256 liquid = $.usdc.balanceOf(address(this));
        if (liquid >= amount) return;
        _refillUsdc(amount - liquid);
        if ($.usdc.balanceOf(address(this)) < amount) revert InsufficientLiquidity();
    }

    /*//////////////////////////////////////////////////////////////
              FX INVENTORY SINK — Morpho FX-loan (native terms)
    //////////////////////////////////////////////////////////////*/

    /// @notice Fund the router with `amount` of FX `token` (non-retail junior/protocol inventory).
    function depositFx(address token, uint256 amount) external onlyRole(FUNDER_ROLE) whenNotPaused nonReentrant {
        RouterStorage storage $ = _s();
        FxAsset storage a = $.fxAsset[token];
        if (!a.managed) revert FxNotManaged();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        a.principal += received;
        emit FxFunded(token, received);
    }

    /// @notice Return up to `token`'s principal to `to` (pulling from Morpho if the buffer is short).
    function withdrawFx(address token, uint256 amount, address to) external onlyRole(FUNDER_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        RouterStorage storage $ = _s();
        FxAsset storage a = $.fxAsset[token];
        if (!a.managed) revert FxNotManaged();
        if (a.principal < amount) revert TierPrincipalShort();
        _ensureLiquidFx(token, amount);
        a.principal -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit FxDefunded(token, amount, to);
    }

    /// @notice Permissionless (s,S) for an FX token: supply excess to its Morpho FX-loan market, or
    ///         withdraw to refill the buffer.
    function rebalanceFx(address token) external whenNotPaused nonReentrant {
        RouterStorage storage $ = _s();
        FxAsset storage a = $.fxAsset[token];
        if (!a.managed || !a.morphoEnabled) revert FxNotManaged();
        uint256 liquid = IERC20(token).balanceOf(address(this));
        if (liquid > a.highWaterToken) {
            uint256 amt = liquid - a.highWaterToken;
            _morphoSupply(a.morphoMarket, amt);
            emit FxSuppliedToMorpho(token, amt);
        } else if (liquid < a.lowWaterToken) {
            uint256 need = a.lowWaterToken - liquid;
            uint256 live = _morphoLiveAssets(a.morphoMarket);
            uint256 pull = need < live ? need : live;
            if (pull == 0) revert RebalanceNoOp();
            uint256 w = _morphoWithdraw(a.morphoMarket, pull);
            emit FxWithdrawnFromMorpho(token, w);
        } else {
            revert RebalanceNoOp();
        }
    }

    /// @notice Send accrued FX yield (value above principal, native token terms) to `to`.
    function harvestFxYield(address token, address to, uint256 amount)
        external
        onlyRole(GOVERNOR_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount > fxAccruedYield(token)) revert YieldShort();
        _ensureLiquidFx(token, amount);
        IERC20(token).safeTransfer(to, amount);
        emit FxYieldHarvested(token, to, amount);
    }

    function _ensureLiquidFx(address token, uint256 amount) internal {
        RouterStorage storage $ = _s();
        FxAsset storage a = $.fxAsset[token];
        uint256 liquid = IERC20(token).balanceOf(address(this));
        if (liquid >= amount) return;
        uint256 need = amount - liquid;
        if (a.morphoEnabled) {
            uint256 live = _morphoLiveAssets(a.morphoMarket);
            uint256 pull = need < live ? need : live;
            if (pull > 0) _morphoWithdraw(a.morphoMarket, pull);
        }
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientLiquidity();
    }

    /*//////////////////////////////////////////////////////////////
                          MORPHO INTERNALS (mirror vault)
    //////////////////////////////////////////////////////////////*/
    function _morphoSupply(MarketParams memory m, uint256 assets) internal {
        RouterStorage storage $ = _s();
        IERC20(m.loanToken).forceApprove(address($.morpho), assets);
        $.morpho.supply(m, assets, 0, address(this), "");
    }

    function _morphoWithdraw(MarketParams memory m, uint256 assets) internal returns (uint256 withdrawn) {
        (withdrawn,) = _s().morpho.withdraw(m, assets, 0, address(this), address(this));
    }

    function _morphoLiveAssets(MarketParams memory m) internal view returns (uint256) {
        RouterStorage storage $ = _s();
        if (address($.morpho) == address(0)) return 0;
        Id id = m.id();
        Market memory mk = $.morpho.market(id);
        if (mk.totalSupplyShares == 0) return 0;
        uint256 shares = $.morpho.position(id, address(this)).supplyShares;
        return shares.toAssetsDown(mk.totalSupplyAssets, mk.totalSupplyShares);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE (BOUNDED / ADMIN)
    //////////////////////////////////////////////////////////////*/
    function setWaterMarks(uint256 lowWaterUsdc_, uint256 highWaterUsdc_) external onlyRole(GOVERNOR_ROLE) {
        if (highWaterUsdc_ < lowWaterUsdc_) revert BadWaterMarks();
        RouterStorage storage $ = _s();
        $.lowWaterUsdc = lowWaterUsdc_;
        $.highWaterUsdc = highWaterUsdc_;
        emit WaterMarksUpdated(lowWaterUsdc_, highWaterUsdc_);
    }

    function setTeller(IUsycTeller teller_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(teller_) == address(0)) revert ZeroAddress();
        RouterStorage storage $ = _s();
        if ($.usyc.balanceOf(address(this)) != 0) revert TellerHasPosition();
        if (teller_.asset() != address($.usdc)) revert TellerAssetMismatch();
        $.teller = teller_;
        emit TellerUpdated(address(teller_));
    }

    /// @notice Wire Morpho Blue. address(0) leaves all Morpho sinks disabled (USYC-only mode).
    function setMorpho(IMorpho morpho_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().morpho = morpho_;
        emit MorphoUpdated(address(morpho_));
    }

    /// @notice Configure the USDC-loan Morpho market + the deploy split (bps of deployable USDC → Morpho).
    function setUsdcMorphoMarket(MarketParams calldata m, bool enabled, uint16 targetBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        RouterStorage storage $ = _s();
        if (enabled && address($.morpho) == address(0)) revert MorphoNotSet();
        if (m.loanToken != address($.usdc)) revert MarketLoanTokenMismatch();
        if (targetBps > BPS) revert ParamOutOfBounds();
        $.usdcMorphoMarket = m;
        $.usdcMorphoEnabled = enabled;
        $.usdcMorphoTargetBps = targetBps;
        emit UsdcMorphoMarketSet(enabled, targetBps);
    }

    function setUsdcMorphoTargetBps(uint16 targetBps) external onlyRole(GOVERNOR_ROLE) {
        if (targetBps > BPS) revert ParamOutOfBounds();
        _s().usdcMorphoTargetBps = targetBps;
        emit UsdcMorphoMarketSet(_s().usdcMorphoEnabled, targetBps);
    }

    /// @notice Register an FX-loan Morpho market for `token` (token == loanToken, USDC collateral).
    function addFxMarket(address token, MarketParams calldata m, uint256 lowWater, uint256 highWater)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        RouterStorage storage $ = _s();
        if (address($.morpho) == address(0)) revert MorphoNotSet();
        if (token == address(0) || token == address($.usdc)) revert NotAnFxToken();
        if (m.loanToken != token) revert MarketLoanTokenMismatch();
        if (highWater < lowWater) revert BadWaterMarks();
        FxAsset storage a = $.fxAsset[token];
        if (!a.managed) $.fxTokenList.push(token);
        a.managed = true;
        a.morphoEnabled = true;
        a.morphoMarket = m;
        a.lowWaterToken = lowWater;
        a.highWaterToken = highWater;
        emit FxMarketSet(token, lowWater, highWater);
    }

    function setFxWaterMarks(address token, uint256 lowWater, uint256 highWater) external onlyRole(GOVERNOR_ROLE) {
        RouterStorage storage $ = _s();
        FxAsset storage a = $.fxAsset[token];
        if (!a.managed) revert FxNotManaged();
        if (highWater < lowWater) revert BadWaterMarks();
        a.lowWaterToken = lowWater;
        a.highWaterToken = highWater;
        emit FxMarketSet(token, lowWater, highWater);
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS — USDC (USD NAV)
    //////////////////////////////////////////////////////////////*/
    function liquidUsdc() public view returns (uint256) {
        return _s().usdc.balanceOf(address(this));
    }

    function usycValueUsdc() public view returns (uint256) {
        RouterStorage storage $ = _s();
        uint256 bal = $.usyc.balanceOf(address(this));
        return bal == 0 ? 0 : $.teller.previewRedeem(bal);
    }

    /// @notice Live USDC supplied to the Morpho USDC-loan market (NAV component).
    function usdcMorphoAssets() public view returns (uint256) {
        RouterStorage storage $ = _s();
        if (!$.usdcMorphoEnabled) return 0;
        return _morphoLiveAssets($.usdcMorphoMarket);
    }

    /// @notice Total USDC-equivalent the router controls = liquid + USYC NAV + Morpho USDC. Oracle-free.
    function yieldAssets() public view returns (uint256) {
        return liquidUsdc() + usycValueUsdc() + usdcMorphoAssets();
    }

    function totalPrincipalUsdc() public view returns (uint256) {
        RouterStorage storage $ = _s();
        return $.principal[Tier.RETAIL] + $.principal[Tier.INSTITUTIONAL] + $.principal[Tier.PROTOCOL];
    }

    function tierPrincipal(Tier tier) external view returns (uint256) {
        return _s().principal[tier];
    }

    function accruedYieldUsdc() public view returns (uint256) {
        uint256 value = yieldAssets();
        uint256 principal = totalPrincipalUsdc();
        return value > principal ? value - principal : 0;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEWS — FX (native terms)
    //////////////////////////////////////////////////////////////*/
    /// @notice Total value of an FX token the router controls = liquid + Morpho-supplied (native units).
    function fxAssets(address token) public view returns (uint256) {
        RouterStorage storage $ = _s();
        FxAsset storage a = $.fxAsset[token];
        uint256 liquid = IERC20(token).balanceOf(address(this));
        return a.morphoEnabled ? liquid + _morphoLiveAssets(a.morphoMarket) : liquid;
    }

    function fxPrincipal(address token) external view returns (uint256) {
        return _s().fxAsset[token].principal;
    }

    function fxAccruedYield(address token) public view returns (uint256) {
        uint256 value = fxAssets(token);
        uint256 principal = _s().fxAsset[token].principal;
        return value > principal ? value - principal : 0;
    }

    function fxConfig(address token)
        external
        view
        returns (bool managed, bool morphoEnabled, uint256 lowWater, uint256 highWater)
    {
        FxAsset storage a = _s().fxAsset[token];
        return (a.managed, a.morphoEnabled, a.lowWaterToken, a.highWaterToken);
    }

    function fxTokens() external view returns (address[] memory) {
        return _s().fxTokenList;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS — config
    //////////////////////////////////////////////////////////////*/
    function waterMarks() external view returns (uint256 low, uint256 high) {
        RouterStorage storage $ = _s();
        return ($.lowWaterUsdc, $.highWaterUsdc);
    }

    function teller() external view returns (address) {
        return address(_s().teller);
    }

    function morpho() external view returns (address) {
        return address(_s().morpho);
    }

    function usdcMorphoConfig() external view returns (bool enabled, uint16 targetBps) {
        RouterStorage storage $ = _s();
        return ($.usdcMorphoEnabled, $.usdcMorphoTargetBps);
    }

    function usdc() external view returns (address) {
        return address(_s().usdc);
    }

    function usyc() external view returns (address) {
        return address(_s().usyc);
    }
}
