// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Constants} from "privacy-pools/contracts/lib/Constants.sol";
import {PrivacyPool} from "privacy-pools/contracts/PrivacyPool.sol";
import {IPrivacyPoolComplex} from "privacy-pools/interfaces/IPrivacyPool.sol";

/// @title FxPrivacyPool
/// @notice fx-Telaraña ERC20 Privacy Pool. Slice 1: thin wrapper that
///         brings deposit/withdraw/ragequit online for a single currency.
///         Owner + Morpho rehypothecation hook points wired for slice 2.
/// @dev    Extends the vendored {PrivacyPool} (0xbow privacy-pools-core,
///         Apache-2.0, audited by Oxorio + Auditware). All cryptographic
///         primitives — Poseidon, lean-IMT, Groth16 verifier — are vendored
///         from PSE / 0xbow at audited commits. No novel math here.
contract FxPrivacyPool is PrivacyPool, IPrivacyPoolComplex {
    using SafeERC20 for IERC20;

    /// @notice Owner — controls future Morpho/rehyp config (slice 2) and
    ///         emergency parameters. Not used by deposit/withdraw paths.
    address public owner;

    event OwnerTransferred(address indexed from, address indexed to);

    error NotOwner();
    // NB: ZeroAddress / NativeAssetNotSupported / NativeAssetNotAccepted are
    // already declared on the vendored IState / IPrivacyPoolComplex surface.

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _entrypoint,
        address _withdrawalVerifier,
        address _ragequitVerifier,
        address _asset,
        address _owner
    ) PrivacyPool(_entrypoint, _withdrawalVerifier, _ragequitVerifier, _asset) {
        if (_asset == Constants.NATIVE_ASSET) revert NativeAssetNotSupported();
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnerTransferred(address(0), _owner);
    }

    /// @notice Rotate the owner. Slice 2 will use this to hand control to a
    ///         timelock-controlled treasury once Morpho rehyp is wired.
    function transferOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    /// @inheritdoc PrivacyPool
    function _pull(address _sender, uint256 _amount) internal override {
        if (msg.value != 0) revert NativeAssetNotAccepted();
        IERC20(ASSET).safeTransferFrom(_sender, address(this), _amount);
        // Slice 2 hook: supply hot-excess to Morpho via IFxMarketRegistry.
    }

    /// @inheritdoc PrivacyPool
    function _push(address _recipient, uint256 _amount) internal override {
        // Slice 2 hook: JIT-withdraw from Morpho if hot reserve < _amount.
        IERC20(ASSET).safeTransfer(_recipient, _amount);
    }
}
