// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFxUsycAdapter} from "./interfaces/IFxUsycAdapter.sol";
import {IUsycTeller} from "./interfaces/IUsycTeller.sol";

/// @title  FxUsycAdapter
/// @notice Arc-only entitled holder for USYC. The vault/keeper moves USDC here,
///         this contract subscribes/redeems through the Circle/Hashnote Teller,
///         and `yieldAssets()` marks the position with `previewRedeem`.
/// @dev    The adapter must be Circle-entitled before live deposit/redeem calls.
///         It owns no swap path and should only receive keeper/vault approvals.
contract FxUsycAdapter is IFxUsycAdapter, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC20 public immutable USDC;
    IERC20 public immutable USYC;
    IUsycTeller public immutable TELLER;

    error ZeroAddress();
    error AmountZero();
    error TellerAssetMismatch();
    error InsufficientYieldPosition();

    event DepositedToYield(uint256 assets, uint256 shares);
    event RedeemedFromYield(uint256 shares, uint256 assets, address indexed receiver);

    constructor(IERC20 usdc_, IERC20 usyc_, IUsycTeller teller_, address admin, address keeper) {
        if (
            address(usdc_) == address(0) || address(usyc_) == address(0) || address(teller_) == address(0)
                || admin == address(0)
        ) revert ZeroAddress();
        if (teller_.asset() != address(usdc_)) revert TellerAssetMismatch();

        USDC = usdc_;
        USYC = usyc_;
        TELLER = teller_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (keeper != address(0)) _grantRole(KEEPER_ROLE, keeper);
    }

    /// @inheritdoc IFxUsycAdapter
    function depositToYield(uint256 assets)
        external
        override
        onlyRole(KEEPER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert AmountZero();
        USDC.safeTransferFrom(msg.sender, address(this), assets);
        USDC.forceApprove(address(TELLER), assets);
        shares = TELLER.deposit(assets, address(this));
        emit DepositedToYield(assets, shares);
    }

    /// @inheritdoc IFxUsycAdapter
    function redeemFromYield(uint256 assets, address receiver)
        external
        override
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 usdcOut)
    {
        if (assets == 0) revert AmountZero();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 held = USYC.balanceOf(address(this));
        if (held == 0) revert InsufficientYieldPosition();

        uint256 shares = assets >= TELLER.previewRedeem(held) ? held : TELLER.previewWithdraw(assets);
        if (shares == 0 || shares > held) revert InsufficientYieldPosition();

        USYC.forceApprove(address(TELLER), shares);
        usdcOut = TELLER.redeem(shares, receiver, address(this));
        emit RedeemedFromYield(shares, usdcOut, receiver);
    }

    /// @inheritdoc IFxUsycAdapter
    function yieldAssets() public view override returns (uint256) {
        uint256 held = USYC.balanceOf(address(this));
        uint256 usycAssets = held == 0 ? 0 : TELLER.previewRedeem(held);
        return USDC.balanceOf(address(this)) + usycAssets;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
