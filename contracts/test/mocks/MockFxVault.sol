// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title MockFxVault
/// @notice Minimal stand-in for SharedFxVault implementing only the READ surface
///         that FxSwapHook touches in unit tests:
///           * `asset()`               — the ERC4626 underlying (USDC) used by the
///                                       hook's `_vaultReserve` branch.
///           * `juniorUsdc()`          — reserve for `asset`.
///           * `juniorTokenBalance()`  — reserve for any FX token.
///         The hook's `_vaultReserve(token)` reads exactly these:
///           token == VAULT.asset() ? VAULT.juniorUsdc() : VAULT.juniorTokenBalance(token).
///         `setReserve` lets tests drive both targets directly, replacing what the
///         removed `deposit()` self-custody path used to do.
/// @dev    `fundFill` / `recordInflow` are no-ops here: these unit tests exercise
///         only the view/quote/sync surface, never a live PoolManager fill. They are
///         included so the implemented surface matches the hook's full VAULT call set.
contract MockFxVault {
    address public asset;
    mapping(address => uint256) public reserve;

    constructor(address asset_) {
        asset = asset_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setReserve(address token, uint256 amt) external {
        reserve[token] = amt;
    }

    function juniorUsdc() external view returns (uint256) {
        return reserve[asset];
    }

    function juniorTokenBalance(address token) external view returns (uint256) {
        return reserve[token];
    }

    // ---- Fill surface: no-ops, not exercised by these unit tests ----
    function fundFill(address, uint256, address) external {}

    function recordInflow(address) external {}
}
