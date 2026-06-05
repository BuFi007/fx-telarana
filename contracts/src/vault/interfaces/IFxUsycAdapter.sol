// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFxUsycAdapter
/// @notice Minimal vault-facing surface for the Arc-only USYC holder.
interface IFxUsycAdapter {
    /// @notice Pull `assets` USDC from the caller and subscribe into USYC.
    function depositToYield(uint256 assets) external returns (uint256 shares);

    /// @notice Redeem enough USYC to recover up to `assets` USDC to `receiver`.
    function redeemFromYield(uint256 assets, address receiver) external returns (uint256 usdcOut);

    /// @notice USDC-equivalent assets controlled by the adapter, including Teller NAV.
    function yieldAssets() external view returns (uint256);
}
