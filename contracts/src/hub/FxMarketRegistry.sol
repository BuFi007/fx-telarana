// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IMorpho, MarketParams as MorphoMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {IFxMarketRegistry} from "../interfaces/IFxMarketRegistry.sol";

/// @title FxMarketRegistry
/// @notice Single-surface router over Morpho Blue isolated markets.
///
/// fx-Telaraña at MVP runs two markets:
///   M1: loan = EURC,  collateral = USDC,  oracle = FxOracle, irm = AdaptiveCurveIrm
///   M2: loan = USDC,  collateral = EURC,  oracle = FxOracle, irm = AdaptiveCurveIrm
///
/// Lenders supply only the loan asset of one market; that's their lending position.
/// Borrowers supply collateral on the *other* market. The registry hides Morpho's
/// MarketParams struct from callers — they pass (loanToken, collateralToken).
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  supply / withdraw / borrow / repay / supplyCollateral / ...    │
/// │       │                                                         │
/// │       ├─► paramsOf(loan, collat) → MarketParams                 │
/// │       ├─► pull tokens from msg.sender, approve Morpho           │
/// │       ├─► IMorpho.supply / borrow / repay / ...                 │
/// │       └─► return shares / assets                                │
/// └─────────────────────────────────────────────────────────────────┘
contract FxMarketRegistry is IFxMarketRegistry, AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MorphoMarketParams;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Operations role — hot actions (pause/unpause) bypass the
    ///         timelock. Spec §10.4: pause must react in <24h.
    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IMorpho public immutable MORPHO;

    /// @notice (loanToken, collateralToken) → marketId.
    mapping(address => mapping(address => bytes32)) private _marketIdOf;

    /// @notice marketId → MarketParams (cached so we don't re-derive each call).
    mapping(bytes32 => MarketParams) private _paramsOf;

    /// @notice marketId → entry-side live flag. Withdraw/repay remain available.
    mapping(bytes32 => bool) private _isLive;

    /// @notice Enumerable list of every registered market id. Order is registration order.
    ///         Spec §6.1 integrator surface — fed to `listPools()` for indexers/monitors.
    bytes32[] private _allMarketIds;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    /// @param initialAdmin Address that initially holds `DEFAULT_ADMIN_ROLE`
    ///                     AND `OPERATIONS_ROLE`. Deploy scripts grant this
    ///                     to the deployer for bootstrap, then atomically
    ///                     transfer DEFAULT_ADMIN_ROLE to FxTimelock and
    ///                     keep OPERATIONS_ROLE on the deployer/multisig.
    constructor(address morpho_, address initialAdmin) {
        if (morpho_ == address(0) || initialAdmin == address(0)) revert ZeroAddress();
        MORPHO = IMorpho(morpho_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Register an existing Morpho market under (loanToken, collateralToken).
    /// @dev    Spec §10.3: addAsset is timelock-gated.
    function registerMarket(MarketParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes32 marketId) {
        if (p.loanToken == address(0) || p.collateralToken == address(0)) revert InvalidParams();
        if (p.oracle == address(0) || p.irm == address(0)) revert InvalidParams();
        if (_marketIdOf[p.loanToken][p.collateralToken] != bytes32(0)) {
            revert MarketAlreadyRegistered(_marketIdOf[p.loanToken][p.collateralToken]);
        }

        MorphoMarketParams memory mp = _toMorpho(p);
        marketId = Id.unwrap(mp.id());

        _marketIdOf[p.loanToken][p.collateralToken] = marketId;
        _paramsOf[marketId] = p;
        _isLive[marketId] = true;
        _allMarketIds.push(marketId);

        emit MarketRegistered(marketId, p.loanToken, p.collateralToken, p.irm, p.lltv);
    }

    /// @notice Create a Morpho market and register it in one shot.
    /// @dev    Spec §10.3: addAsset is timelock-gated.
    function createAndRegisterMarket(MarketParams calldata p)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes32 marketId)
    {
        MorphoMarketParams memory mp = _toMorpho(p);
        MORPHO.createMarket(mp);
        marketId = Id.unwrap(mp.id());

        if (_marketIdOf[p.loanToken][p.collateralToken] != bytes32(0)) {
            revert MarketAlreadyRegistered(_marketIdOf[p.loanToken][p.collateralToken]);
        }
        _marketIdOf[p.loanToken][p.collateralToken] = marketId;
        _paramsOf[marketId] = p;
        _isLive[marketId] = true;
        _allMarketIds.push(marketId);

        emit MarketRegistered(marketId, p.loanToken, p.collateralToken, p.irm, p.lltv);
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Hot-path emergency stop. Spec §10.4: OPERATIONS_ROLE bypass.
    ///         Entry-side actions (supply/supplyCollateral/borrow) revert
    ///         while paused. Exit-side (withdraw/repay) always works.
    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    /// @notice Hot per-pair incident-response toggle. Exit-side actions remain open.
    function setPoolLive(address loanToken, address collateralToken, bool isLive) external onlyRole(OPERATIONS_ROLE) {
        bytes32 marketId = marketIdOf(loanToken, collateralToken);
        _isLive[marketId] = isLive;
        emit PoolLiveSet(marketId, isLive);
    }

    /*//////////////////////////////////////////////////////////////
                                ROUTING
    //////////////////////////////////////////////////////////////*/

    function marketIdOf(address loanToken, address collateralToken) public view returns (bytes32 id) {
        id = _marketIdOf[loanToken][collateralToken];
        if (id == bytes32(0)) revert UnknownMarket(loanToken, collateralToken);
    }

    function paramsOf(address loanToken, address collateralToken) public view returns (MarketParams memory) {
        return _paramsOf[marketIdOf(loanToken, collateralToken)];
    }

    /// @notice Enumerate every registered pool's MarketParams in registration order.
    /// @dev    Spec §6.1 integrator surface. O(N) and unbounded; for indexers, not
    ///         hot-path callers. N is the basket size (≤10 in Phase 3 sequencing).
    function listPools() external view returns (MarketParams[] memory pools) {
        uint256 n = _allMarketIds.length;
        pools = new MarketParams[](n);
        for (uint256 i = 0; i < n; ++i) {
            pools[i] = _paramsOf[_allMarketIds[i]];
        }
    }

    function isPoolLive(address loanToken, address collateralToken) external view returns (bool) {
        return _isLive[marketIdOf(loanToken, collateralToken)];
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function supply(address loanToken, address collateralToken, uint256 assets, address onBehalf)
        external
        whenNotPaused
        returns (uint256 sharesMinted)
    {
        bytes32 marketId = marketIdOf(loanToken, collateralToken);
        _assertPairLive(marketId);
        MorphoMarketParams memory mp = _toMorpho(_paramsOf[marketId]);

        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), assets);
        _ensureApproval(IERC20(loanToken), address(MORPHO), assets);

        (, sharesMinted) = MORPHO.supply(mp, assets, 0, onBehalf, "");
    }

    function withdraw(address loanToken, address collateralToken, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsOut)
    {
        // Morpho's setAuthorization(registry) is registry-wide. The registry
        // therefore MUST gate every withdraw at the caller level — otherwise
        // an attacker can drain any user who authorized the registry by
        // setting `onBehalf=victim, receiver=attacker`. See
        // `NotAuthorizedForOnBehalf` doc on IFxMarketRegistry.
        if (onBehalf != msg.sender) revert NotAuthorizedForOnBehalf(onBehalf, msg.sender);
        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);
        (assetsOut,) = MORPHO.withdraw(mp, 0, shares, onBehalf, receiver);
    }

    function supplyCollateral(address loanToken, address collateralToken, uint256 collateral, address onBehalf)
        external
        whenNotPaused
    {
        bytes32 marketId = marketIdOf(loanToken, collateralToken);
        _assertPairLive(marketId);
        MorphoMarketParams memory mp = _toMorpho(_paramsOf[marketId]);

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateral);
        _ensureApproval(IERC20(collateralToken), address(MORPHO), collateral);

        MORPHO.supplyCollateral(mp, collateral, onBehalf, "");
    }

    function withdrawCollateral(
        address loanToken,
        address collateralToken,
        uint256 collateral,
        address onBehalf,
        address receiver
    ) external {
        if (onBehalf != msg.sender) revert NotAuthorizedForOnBehalf(onBehalf, msg.sender);
        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);
        MORPHO.withdrawCollateral(mp, collateral, onBehalf, receiver);
    }

    function borrow(address loanToken, address collateralToken, uint256 assets, address onBehalf, address receiver)
        external
        whenNotPaused
        returns (uint256 borrowedShares)
    {
        if (onBehalf != msg.sender) revert NotAuthorizedForOnBehalf(onBehalf, msg.sender);
        bytes32 marketId = marketIdOf(loanToken, collateralToken);
        _assertPairLive(marketId);
        MorphoMarketParams memory mp = _toMorpho(_paramsOf[marketId]);
        (, borrowedShares) = MORPHO.borrow(mp, assets, 0, onBehalf, receiver);
    }

    function repay(address loanToken, address collateralToken, uint256 assets, address onBehalf)
        external
        returns (uint256 sharesBurned)
    {
        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);

        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), assets);
        _ensureApproval(IERC20(loanToken), address(MORPHO), assets);

        (, sharesBurned) = MORPHO.repay(mp, assets, 0, onBehalf, "");
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _morphoParams(address loanToken, address collateralToken)
        internal
        view
        returns (MorphoMarketParams memory)
    {
        MarketParams memory p = _paramsOf[marketIdOf(loanToken, collateralToken)];
        return _toMorpho(p);
    }

    function _assertPairLive(bytes32 marketId) internal view {
        if (!_isLive[marketId]) revert PoolNotLive(marketId);
    }

    function _toMorpho(MarketParams memory p) internal pure returns (MorphoMarketParams memory) {
        return MorphoMarketParams({
            loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv
        });
    }

    function _ensureApproval(IERC20 token, address spender, uint256 needed) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current < needed) {
            if (current != 0) token.forceApprove(spender, 0);
            token.forceApprove(spender, type(uint256).max);
        }
    }
}
