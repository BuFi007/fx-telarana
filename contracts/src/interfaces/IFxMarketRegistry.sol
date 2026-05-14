// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFxMarketRegistry
/// @notice Single-surface router over Morpho Blue isolated markets.
///
/// fx-Telaraña runs (at MVP) two isolated Morpho Blue markets:
///   M1: loan = EURC, collateral = USDC, oracle = FxOracle EUR/USD, irm = AdaptiveCurve
///   M2: loan = USDC, collateral = EURC, oracle = FxOracle USD/EUR, irm = AdaptiveCurve
///
/// Each market is identified by a Morpho `Id` (bytes32 of the MarketParams hash).
/// This registry maps (loanToken, collateralToken) → marketId and exposes one
/// supply/withdraw/borrow/repay surface so callers don't carry market params.
///
/// Liquidation is handled by `FxLiquidator` directly against Morpho.
interface IFxMarketRegistry {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnknownMarket(address loanToken, address collateralToken);
    error MarketAlreadyRegistered(bytes32 marketId);
    error InvalidParams();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketRegistered(
        bytes32 indexed marketId,
        address indexed loanToken,
        address indexed collateralToken,
        address irm,
        uint256 lltv
    );

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mirrors Morpho's `MarketParams` for ABI parity.
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    /*//////////////////////////////////////////////////////////////
                                ROUTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the Morpho market id for a (loan, collateral) pair.
    function marketIdOf(address loanToken, address collateralToken) external view returns (bytes32);

    /// @notice Returns the full Morpho MarketParams for a (loan, collateral) pair.
    function paramsOf(address loanToken, address collateralToken) external view returns (MarketParams memory);

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Supply `assets` of `loanToken` as a lender. Receives Morpho supply shares
    ///         (tracked in storage). Use `FxReceipt` ERC-4626 wrapper for an aggregate view.
    function supply(
        address loanToken,
        address collateralToken,
        uint256 assets,
        address onBehalf
    ) external returns (uint256 sharesMinted);

    /// @notice Withdraw shares back to `loanToken`.
    function withdraw(
        address loanToken,
        address collateralToken,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsOut);

    /// @notice Supply `collateral` to back a borrow position.
    function supplyCollateral(
        address loanToken,
        address collateralToken,
        uint256 collateral,
        address onBehalf
    ) external;

    /// @notice Withdraw collateral (must keep position healthy).
    function withdrawCollateral(
        address loanToken,
        address collateralToken,
        uint256 collateral,
        address onBehalf,
        address receiver
    ) external;

    /// @notice Borrow `assets` of `loanToken` against existing collateral.
    function borrow(
        address loanToken,
        address collateralToken,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external returns (uint256 borrowedShares);

    /// @notice Repay an existing debt position.
    function repay(
        address loanToken,
        address collateralToken,
        uint256 assets,
        address onBehalf
    ) external returns (uint256 sharesBurned);
}
