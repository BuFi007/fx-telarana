// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TestnetFiatToken
/// @notice Role-gated stable-token mock for testnet spot markets. Replaces
///         the unrestricted `contracts/test/mocks/MockERC20.sol` shipped in
///         Phase A v0, which Codex flagged HIGH (2026-05-16):
///         "any testnet account can burn the executor's tokenOut reserves
///         or mint unbounded balances, making smoke results and keeper
///         behavior non-representative and trivially griefable."
///
///         This token:
///           * Mints via MINTER_ROLE only.
///           * Burns only the caller's own balance via `burn()` /
///             `burnFrom()` (allowance-gated) inherited from OZ
///             `ERC20Burnable`. **There is no privileged burn-anyone path.**
///           * Configurable decimals via constructor (testnet stables ship
///             6-dec to match USDC; FxSpotExecutor enforces equal-decimals
///             at allowlist time).
///           * Role transfer + revoke through OZ `AccessControl`.
///
/// Used to back the testnet JPYC / MXNB / CHFC spot routes on Arc until
/// real issuer-route assets (Hyperlane lane) land.
contract TestnetFiatToken is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address initialAdmin
    ) ERC20(name_, symbol_) {
        require(initialAdmin != address(0), "TestnetFiatToken: zero admin");
        _decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(MINTER_ROLE, initialAdmin);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice MINTER_ROLE-gated mint. The unrestricted public `mint` on the
    ///         legacy mock was the griefing surface. Issuance is centralized
    ///         on testnet — matches mainnet issuer-controlled reality.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
