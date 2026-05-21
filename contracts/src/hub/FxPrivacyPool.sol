// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

import {IFxMarketRegistry} from "../interfaces/IFxMarketRegistry.sol";

import {Constants} from "privacy-pools/contracts/lib/Constants.sol";
import {PrivacyPool} from "privacy-pools/contracts/PrivacyPool.sol";
import {IPrivacyPoolComplex} from "privacy-pools/interfaces/IPrivacyPool.sol";

/// @title FxPrivacyPool
/// @notice fx-Telaraña ERC20 Privacy Pool with Morpho yield rehypothecation.
///
///         Slice 2: deposits keep a `hotReservePct` fraction liquid for fast
///         withdrawals; the remainder is supplied to the Morpho Blue market
///         where ASSET is the loan token (paired against COLLATERAL).
///         Withdraws JIT-pull from Morpho when the hot reserve is short.
///
///         Rehyp pattern lifted verbatim from FxSwapHook.sol:1014-1069 —
///         same {paramsOf,supply,withdraw,expectedSupplyAssets} surface.
///         No novel math; all primitives vendored from audited sources.
contract FxPrivacyPool is PrivacyPool, IPrivacyPoolComplex {
    using SafeERC20 for IERC20;
    using MorphoBalancesLib for IMorpho;

    /// @notice 100% in bps. hotReservePct uses this denominator.
    uint16 public constant BPS_DENOM = 10_000;
    /// @notice Default fraction of deposits kept in hot reserve (20%).
    ///         Same default FxSwapHook ships with.
    uint16 public constant DEFAULT_HOT_RESERVE_PCT = 2_000;

    /// @notice Owner — controls `hotReservePct` and treasury rotation.
    address public owner;

    /// @notice Morpho Blue protocol address (immutable).
    IMorpho public immutable MORPHO;
    /// @notice Fx market registry providing Morpho MarketParams for our pair.
    IFxMarketRegistry public immutable REGISTRY;
    /// @notice The collateral side of the Morpho market we supply into.
    ///         ASSET is the loan side; COLLATERAL is the pair token (e.g.
    ///         USDC pool's collateral is EURC, and vice versa).
    address public immutable COLLATERAL;

    /// @notice Fraction of effective assets kept hot (denominated in BPS).
    ///         100% = `BPS_DENOM` = no Morpho supply (all hot).
    uint16 public hotReservePct;

    /// @notice Bookkeeping of our Morpho supply shares for ASSET. Cheap
    ///         re-entrancy guard for views — short-circuits the registry
    ///         lookup when zero.
    uint256 public morphoShares;

    event OwnerTransferred(address indexed from, address indexed to);
    event HotReservePctSet(uint16 oldBps, uint16 newBps);
    event Rehypothecated(uint256 assets, uint256 totalShares);
    event WithdrawnFromMorpho(uint256 assets, uint256 totalShares);

    error NotOwner();
    error InvalidHotReservePct();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _entrypoint,
        address _withdrawalVerifier,
        address _ragequitVerifier,
        address _asset,
        address _owner,
        address _morpho,
        address _registry,
        address _collateral
    ) PrivacyPool(_entrypoint, _withdrawalVerifier, _ragequitVerifier, _asset) {
        if (_asset == Constants.NATIVE_ASSET) revert NativeAssetNotSupported();
        if (_owner == address(0)) revert ZeroAddress();
        if (_morpho == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        if (_collateral == address(0)) revert ZeroAddress();
        if (_collateral == _asset) revert ZeroAddress();

        owner         = _owner;
        MORPHO        = IMorpho(_morpho);
        REGISTRY      = IFxMarketRegistry(_registry);
        COLLATERAL    = _collateral;
        hotReservePct = DEFAULT_HOT_RESERVE_PCT;

        emit OwnerTransferred(address(0), _owner);
        emit HotReservePctSet(0, DEFAULT_HOT_RESERVE_PCT);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNER CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rotate the owner.
    function transferOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    /// @notice Adjust the hot-reserve fraction. 10_000 = 100% (full hot,
    ///         no Morpho supply). 0 = aggressive (everything in Morpho;
    ///         every withdraw JIT-withdraws). Triggers a one-shot
    ///         rebalance against the new target.
    function setHotReservePct(uint16 _bps) external onlyOwner {
        if (_bps > BPS_DENOM) revert InvalidHotReservePct();
        emit HotReservePctSet(hotReservePct, _bps);
        hotReservePct = _bps;
        _rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total assets under management: hot balance + Morpho supply.
    function totalAssets() external view returns (uint256) {
        return _hotBalance() + _morphoSupplyAssets();
    }

    /// @notice Hot ASSET balance held directly by the contract.
    function hotBalance() external view returns (uint256) {
        return _hotBalance();
    }

    /// @notice Morpho supply assets attributable to this pool.
    function morphoSupplyAssets() external view returns (uint256) {
        return _morphoSupplyAssets();
    }

    /*//////////////////////////////////////////////////////////////
                          PrivacyPool overrides
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc PrivacyPool
    function _pull(address _sender, uint256 _amount) internal override {
        if (msg.value != 0) revert NativeAssetNotAccepted();
        IERC20(ASSET).safeTransferFrom(_sender, address(this), _amount);
        _rebalance();
    }

    /// @inheritdoc PrivacyPool
    function _push(address _recipient, uint256 _amount) internal override {
        _ensureHot(_amount);
        IERC20(ASSET).safeTransfer(_recipient, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                          MORPHO REHYPOTHECATION
    //////////////////////////////////////////////////////////////*/

    function _hotBalance() internal view returns (uint256) {
        return IERC20(ASSET).balanceOf(address(this));
    }

    function _morphoSupplyAssets() internal view returns (uint256) {
        if (morphoShares == 0) return 0;
        return MORPHO.expectedSupplyAssets(_morphoParams(), address(this));
    }

    function _morphoParams() internal view returns (MorphoMarketParams memory) {
        IFxMarketRegistry.MarketParams memory p = REGISTRY.paramsOf(ASSET, COLLATERAL);
        return MorphoMarketParams({
            loanToken:       p.loanToken,
            collateralToken: p.collateralToken,
            oracle:          p.oracle,
            irm:             p.irm,
            lltv:            p.lltv
        });
    }

    /// @notice Rebalance the hot/Morpho split toward `hotReservePct`.
    ///         Bidirectional: if hot is over target, supply the excess to
    ///         Morpho; if hot is under target (and we have Morpho supply
    ///         to draw on), withdraw the shortfall back to hot. Special
    ///         case `hotReservePct = BPS_DENOM` fully unwinds Morpho —
    ///         critical for owner-driven de-risking.
    ///
    ///         Codex-r1 MED #1: prior version early-returned at 100% hot
    ///         and left existing supply stranded.
    function _rebalance() internal {
        uint256 sharesHeld = morphoShares;
        uint256 hot        = _hotBalance();

        // Full-hot mode: unwind everything still in Morpho. Uses shares-mode
        // withdraw so we don't depend on a freshly-accrued `expectedSupplyAssets`
        // figure — burn the exact share balance we hold.
        if (hotReservePct >= BPS_DENOM) {
            if (sharesHeld > 0) _withdrawAllFromMorpho(sharesHeld);
            return;
        }

        uint256 supplied = _morphoSupplyAssets();
        uint256 total    = hot + supplied;
        if (total == 0) return;

        uint256 targetHot = (total * uint256(hotReservePct)) / BPS_DENOM;
        if (hot > targetHot) {
            _supplyToMorpho(hot - targetHot);
        } else if (hot < targetHot && supplied > 0) {
            uint256 needed = targetHot - hot;
            if (needed > supplied) needed = supplied;
            _withdrawFromMorpho(needed);
        }
    }

    /// @notice Burn `shares` of Morpho supply for ASSET — shares-mode
    ///         withdraw. Used by the full-unwind path (`hotReservePct = 100%`)
    ///         where we want to exit the exact share balance we hold without
    ///         needing an accurate `expectedSupplyAssets` snapshot.
    function _withdrawAllFromMorpho(uint256 shares) internal {
        if (shares == 0) return;
        MorphoMarketParams memory mp = _morphoParams();
        (uint256 assetsOut, uint256 sharesBurned) =
            MORPHO.withdraw(mp, 0, shares, address(this), address(this));
        morphoShares = sharesBurned > shares ? 0 : shares - sharesBurned;
        emit WithdrawnFromMorpho(assetsOut, morphoShares);
    }

    /// @notice JIT-pull `needed` of ASSET into hot reserve if missing.
    function _ensureHot(uint256 _needed) internal {
        uint256 hot = _hotBalance();
        if (hot >= _needed) return;
        _withdrawFromMorpho(_needed - hot);
    }

    function _supplyToMorpho(uint256 _assets) internal {
        if (_assets == 0) return;
        MorphoMarketParams memory mp = _morphoParams();
        _ensureApproval(IERC20(ASSET), address(MORPHO), _assets);
        (, uint256 sharesSupplied) = MORPHO.supply(mp, _assets, 0, address(this), "");
        morphoShares += sharesSupplied;
        emit Rehypothecated(_assets, morphoShares);
    }

    function _withdrawFromMorpho(uint256 _assets) internal {
        if (_assets == 0) return;
        MorphoMarketParams memory mp = _morphoParams();
        (, uint256 sharesBurned) = MORPHO.withdraw(mp, _assets, 0, address(this), address(this));
        morphoShares = sharesBurned > morphoShares ? 0 : morphoShares - sharesBurned;
        emit WithdrawnFromMorpho(_assets, morphoShares);
    }

    function _ensureApproval(IERC20 _token, address _spender, uint256 _needed) internal {
        uint256 current = _token.allowance(address(this), _spender);
        if (current >= _needed) return;
        if (current != 0) _token.forceApprove(_spender, 0);
        _token.forceApprove(_spender, type(uint256).max);
    }
}
