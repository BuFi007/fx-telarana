// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
contract FxMarketRegistry is IFxMarketRegistry {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MorphoMarketParams;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IMorpho public immutable MORPHO;

    address public owner;

    /// @notice (loanToken, collateralToken) → marketId.
    mapping(address => mapping(address => bytes32)) private _marketIdOf;

    /// @notice marketId → MarketParams (cached so we don't re-derive each call).
    mapping(bytes32 => MarketParams) private _paramsOf;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address morpho_, address owner_) {
        if (morpho_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        MORPHO = IMorpho(morpho_);
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Register an existing Morpho market under (loanToken, collateralToken).
    /// @dev    The market MUST already exist on Morpho Blue. Use `createAndRegister`
    ///         if you also want to create it.
    function registerMarket(MarketParams calldata p) external onlyOwner returns (bytes32 marketId) {
        if (p.loanToken == address(0) || p.collateralToken == address(0)) revert InvalidParams();
        if (p.oracle == address(0) || p.irm == address(0)) revert InvalidParams();
        if (_marketIdOf[p.loanToken][p.collateralToken] != bytes32(0)) {
            revert MarketAlreadyRegistered(_marketIdOf[p.loanToken][p.collateralToken]);
        }

        MorphoMarketParams memory mp = _toMorpho(p);
        marketId = Id.unwrap(mp.id());

        _marketIdOf[p.loanToken][p.collateralToken] = marketId;
        _paramsOf[marketId] = p;

        emit MarketRegistered(marketId, p.loanToken, p.collateralToken, p.irm, p.lltv);
    }

    /// @notice Create a Morpho market and register it in one shot.
    function createAndRegisterMarket(MarketParams calldata p) external onlyOwner returns (bytes32 marketId) {
        MorphoMarketParams memory mp = _toMorpho(p);
        MORPHO.createMarket(mp);
        marketId = Id.unwrap(mp.id());

        if (_marketIdOf[p.loanToken][p.collateralToken] != bytes32(0)) {
            revert MarketAlreadyRegistered(_marketIdOf[p.loanToken][p.collateralToken]);
        }
        _marketIdOf[p.loanToken][p.collateralToken] = marketId;
        _paramsOf[marketId] = p;

        emit MarketRegistered(marketId, p.loanToken, p.collateralToken, p.irm, p.lltv);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                ROUTING
    //////////////////////////////////////////////////////////////*/

    function marketIdOf(address loanToken, address collateralToken) public view returns (bytes32 id) {
        id = _marketIdOf[loanToken][collateralToken];
        if (id == bytes32(0)) revert UnknownMarket(loanToken, collateralToken);
    }

    function paramsOf(address loanToken, address collateralToken)
        public
        view
        returns (MarketParams memory)
    {
        return _paramsOf[marketIdOf(loanToken, collateralToken)];
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function supply(
        address loanToken,
        address collateralToken,
        uint256 assets,
        address onBehalf
    ) external returns (uint256 sharesMinted) {
        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);

        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), assets);
        _ensureApproval(IERC20(loanToken), address(MORPHO), assets);

        (, sharesMinted) = MORPHO.supply(mp, assets, 0, onBehalf, "");
    }

    function withdraw(
        address loanToken,
        address collateralToken,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsOut) {
        // Morpho's setAuthorization(registry) is registry-wide. The registry
        // therefore MUST gate every withdraw at the caller level — otherwise
        // an attacker can drain any user who authorized the registry by
        // setting `onBehalf=victim, receiver=attacker`. See
        // `NotAuthorizedForOnBehalf` doc on IFxMarketRegistry.
        if (onBehalf != msg.sender) revert NotAuthorizedForOnBehalf(onBehalf, msg.sender);
        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);
        (assetsOut, ) = MORPHO.withdraw(mp, 0, shares, onBehalf, receiver);
    }

    function supplyCollateral(
        address loanToken,
        address collateralToken,
        uint256 collateral,
        address onBehalf
    ) external {
        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);

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

    function borrow(
        address loanToken,
        address collateralToken,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external returns (uint256 borrowedShares) {
        if (onBehalf != msg.sender) revert NotAuthorizedForOnBehalf(onBehalf, msg.sender);
        MorphoMarketParams memory mp = _morphoParams(loanToken, collateralToken);
        (, borrowedShares) = MORPHO.borrow(mp, assets, 0, onBehalf, receiver);
    }

    function repay(
        address loanToken,
        address collateralToken,
        uint256 assets,
        address onBehalf
    ) external returns (uint256 sharesBurned) {
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

    function _toMorpho(MarketParams memory p) internal pure returns (MorphoMarketParams memory) {
        return MorphoMarketParams({
            loanToken: p.loanToken,
            collateralToken: p.collateralToken,
            oracle: p.oracle,
            irm: p.irm,
            lltv: p.lltv
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
