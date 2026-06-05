// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IUsycTeller
/// @notice Minimal surface of Circle/Hashnote's USYC Teller (the audited subscribe/redeem
///         contract). Verified live on Arc Testnet at `0x9fdF14c5B14173D74C08Af27AebFf39240dC105A`:
///         ERC-4626-style, `asset()` == Arc native USDC (`0x3600…0000`), atomic T+0 settlement.
/// @dev    `redeem` takes an explicit `account` (the USYC holder) distinct from `receiver`
///         (who gets the USDC) — a contract redeems on its own behalf with both == address(this).
///         Subscription/redemption is gated by the on-chain Entitlements authority on the USYC
///         token; the calling/holding address (EOA or contract) must be entitled.
interface IUsycTeller {
    /// @notice Subscribe: pull `assets` USDC from the caller, mint USYC to `receiver`.
    /// @return shares USYC minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Redeem: burn `shares` USYC held by `account`, send USDC to `receiver`.
    /// @return assets USDC paid out.
    function redeem(uint256 shares, address receiver, address account) external returns (uint256 assets);

    /// @notice USYC minted for `assets` USDC subscribed (current price).
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice USDC paid out for `shares` USYC redeemed (current price). NAV source.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice USYC shares required to redeem exactly `assets` USDC (rounds up). (s,S) refill source.
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice The subscription/redemption asset (USDC).
    function asset() external view returns (address);
}
