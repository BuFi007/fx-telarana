// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Entrypoint} from "privacy-pools/contracts/Entrypoint.sol";
import {IPrivacyPool} from "privacy-pools/interfaces/IPrivacyPool.sol";
import {ProofLib} from "privacy-pools/contracts/lib/ProofLib.sol";

import {IFxRouterSwapAdapter} from "./FxRouter.sol";

/// @title FxPrivacyEntrypoint
/// @notice fx-Telaraña Privacy Pool router. Extends the vendored 0xbow
///         {Entrypoint} (Apache-2.0, audited) with **cross-currency
///         relay**: shield in USDC, unshield in EURC (or any pair token)
///         to a fresh address, routed through `FxSwapHook` via the same
///         `IFxRouterSwapAdapter` PR-6 abstracts for the public FxRouter.
///
///         Storage layout: this contract is UUPS-upgradeable AND its
///         parent `Entrypoint` is vendored from an upstream that may add
///         storage variables in future versions. To prevent slot
///         collisions with future vendor upgrades, fx-Telarana state is
///         held in an ERC-7201 namespaced storage struct (see
///         {FxPrivacyEntrypointStorage}). The fixed deterministic slot
///         lives outside the linearized inheritance chain, so the vendor
///         can append state to {Entrypoint} freely without invalidating
///         our fields.
contract FxPrivacyEntrypoint is Entrypoint {
    using SafeERC20 for IERC20;
    using ProofLib for ProofLib.WithdrawProof;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Carried in the user's `Withdrawal.data` for cross-currency
    ///         relays. The user's Groth16 proof commits to
    ///         `context = keccak256(_withdrawal, SCOPE)`, which covers
    ///         this entire blob — so the swap target and slippage bound
    ///         are signed into the proof. A malicious relayer cannot
    ///         alter `buyToken` or `minBuyAmount` without invalidating
    ///         the ZK proof.
    struct CrossCurrencyRelayData {
        address recipient;
        address feeRecipient;
        uint256 relayFeeBPS;
        address buyToken;
        uint256 minBuyAmount;
    }

    /// @notice ERC-7201 namespaced storage for fx-Telarana state.
    /// @custom:storage-location erc7201:fx.privacy.entrypoint
    struct FxPrivacyEntrypointStorage {
        IFxRouterSwapAdapter swapAdapter;
        mapping(IERC20 _asset => bool _enabled) crossCurrencyEnabled;
        // Fixed-denomination gate. When enabled for an asset, every deposit
        // value and every withdrawal `withdrawnValue` MUST be one of the
        // allowed denominations — this is what gives Ghost Mode an anonymity
        // set on a transparent chain (the amount is necessarily public, so the
        // only privacy lever is making everyone share a small set of amounts).
        // Appended to the END of the struct so existing slots are unchanged on
        // upgrade. See PRIVACY_CIRCUIT_WORKPLAN.md.
        mapping(IERC20 _asset => bool _enabled) denominationGateEnabled;
        mapping(IERC20 _asset => mapping(uint256 _value => bool _ok)) denominationAllowed;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE SLOT
    //////////////////////////////////////////////////////////////*/

    // keccak256(abi.encode(uint256(keccak256("fx.privacy.entrypoint")) - 1))
    //   & ~bytes32(uint256(0xff))
    // Evaluated at compile time. The trailing-byte mask gives us a slot
    // that can never collide with a normal storage allocation.
    bytes32 private constant _STORAGE_SLOT =
        keccak256(abi.encode(uint256(keccak256("fx.privacy.entrypoint")) - 1))
        & ~bytes32(uint256(0xff));

    function _getFxStorage()
        private
        pure
        returns (FxPrivacyEntrypointStorage storage $)
    {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SwapAdapterSet(address indexed oldAdapter, address indexed newAdapter);
    event CrossCurrencyEnabled(IERC20 indexed _asset, bool _enabled);
    event DenominationGateSet(IERC20 indexed _asset, bool _enabled);
    event DenominationsSet(IERC20 indexed _asset, uint256[] _values);

    /// @notice Emitted on a successful cross-currency withdrawal relay.
    /// @param  _relayer     The keeper / SDK relayer that processed the call.
    /// @param  _recipient   The fresh address the user shipped output to.
    /// @param  _sellAsset   The shielded pool asset (e.g. USDC).
    /// @param  _buyAsset    The asset delivered to the recipient (e.g. EURC).
    /// @param  _withdrawnAmount  Gross shielded withdraw, pre-fee.
    /// @param  _feeAmount   Relay fee in `_sellAsset` (paid to `feeRecipient`).
    /// @param  _buyAmount   Output delivered to `_recipient` in `_buyAsset`.
    event CrossCurrencyRelayed(
        address indexed _relayer,
        address indexed _recipient,
        IERC20  indexed _sellAsset,
        IERC20          _buyAsset,
        uint256         _withdrawnAmount,
        uint256         _feeAmount,
        uint256         _buyAmount
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error SwapAdapterNotSet();
    error CrossCurrencyDisabled(IERC20 _asset);
    error BuyTokenEqualsAsset();
    error AdapterUnderdelivered(uint256 received, uint256 minBuyAmount);
    error RecipientUnderdelivered(uint256 received, uint256 minBuyAmount);
    error ZeroRecipient();
    error NotADenomination(IERC20 _asset, uint256 _value);

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Currently wired swap adapter.
    function swapAdapter() external view returns (IFxRouterSwapAdapter) {
        return _getFxStorage().swapAdapter;
    }

    /// @notice Whether cross-currency relays are enabled for `_asset`.
    function crossCurrencyEnabled(IERC20 _asset) external view returns (bool) {
        return _getFxStorage().crossCurrencyEnabled[_asset];
    }

    /// @notice Whether the fixed-denomination gate is enforced for `_asset`.
    function denominationGateEnabled(IERC20 _asset) external view returns (bool) {
        return _getFxStorage().denominationGateEnabled[_asset];
    }

    /// @notice Whether `_value` (atomic units) is an allowed denomination for `_asset`.
    function isDenomination(IERC20 _asset, uint256 _value) public view returns (bool) {
        return _getFxStorage().denominationAllowed[_asset][_value];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Wire (or rotate) the swap adapter. Owner-gated via the
    ///         vendored OZ AccessControl `_OWNER_ROLE`.
    function setSwapAdapter(IFxRouterSwapAdapter _newAdapter) external onlyRole(_OWNER_ROLE) {
        if (address(_newAdapter) == address(0)) revert ZeroAddress();
        FxPrivacyEntrypointStorage storage $ = _getFxStorage();
        emit SwapAdapterSet(address($.swapAdapter), address(_newAdapter));
        $.swapAdapter = _newAdapter;
    }

    /// @notice Toggle cross-currency relays per asset. Off by default;
    ///         owner flips on once a swap adapter + LP exist for the asset.
    function setCrossCurrencyEnabled(IERC20 _asset, bool _enabled) external onlyRole(_OWNER_ROLE) {
        if (address(_asset) == address(0)) revert ZeroAddress();
        _getFxStorage().crossCurrencyEnabled[_asset] = _enabled;
        emit CrossCurrencyEnabled(_asset, _enabled);
    }

    /// @notice Register the allowed denomination set (atomic units) for `_asset`
    ///         and turn the gate ON. Additive — call again to whitelist more
    ///         values. Owner-gated. Stablecoins (6dp): 1e6/10e6/100e6/1000e6/
    ///         10000e6; cirBTC (18dp): 1e15/1e16/1e17/1e18. Mirror the MCP set.
    function setDenominations(IERC20 _asset, uint256[] calldata _values) external onlyRole(_OWNER_ROLE) {
        if (address(_asset) == address(0)) revert ZeroAddress();
        FxPrivacyEntrypointStorage storage $ = _getFxStorage();
        for (uint256 i; i < _values.length; ++i) {
            $.denominationAllowed[_asset][_values[i]] = true;
        }
        $.denominationGateEnabled[_asset] = true;
        emit DenominationsSet(_asset, _values);
        emit DenominationGateSet(_asset, true);
    }

    /// @notice Toggle enforcement of the denomination gate for `_asset` without
    ///         touching the registered set. Owner-gated.
    function setDenominationGateEnabled(IERC20 _asset, bool _enabled) external onlyRole(_OWNER_ROLE) {
        if (address(_asset) == address(0)) revert ZeroAddress();
        _getFxStorage().denominationGateEnabled[_asset] = _enabled;
        emit DenominationGateSet(_asset, _enabled);
    }

    /*//////////////////////////////////////////////////////////////
                        DENOMINATION GATE (hooks)
    //////////////////////////////////////////////////////////////*/

    /// @dev Authoritative on-chain enforcement of the amount-privacy lever:
    ///      every deposit value and every withdrawal `withdrawnValue` must be a
    ///      registered denomination once the gate is on for the asset. The MCP
    ///      advice layer mirrors this, but THIS is the source of truth — a user
    ///      calling the contract directly cannot self-deanonymize with an
    ///      off-denomination amount. No new trusted setup: the deployed
    ///      WithdrawalVerifier is unchanged; this is a value-domain require().
    function _enforceDenomination(IERC20 _asset, uint256 _value) internal view {
        FxPrivacyEntrypointStorage storage $ = _getFxStorage();
        if ($.denominationGateEnabled[_asset] && !$.denominationAllowed[_asset][_value]) {
            revert NotADenomination(_asset, _value);
        }
    }

    /// @inheritdoc Entrypoint
    function _beforeDeposit(IERC20 _asset, uint256 _value) internal view override {
        _enforceDenomination(_asset, _value);
    }

    /// @inheritdoc Entrypoint
    function _beforeWithdraw(IERC20 _asset, uint256 _value) internal view override {
        _enforceDenomination(_asset, _value);
    }

    /*//////////////////////////////////////////////////////////////
                        CROSS-CURRENCY RELAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Process a shielded withdrawal and atomically swap the output
    ///         into a different currency before delivering to the recipient.
    /// @dev    Trust boundary on the adapter: we do NOT trust the adapter's
    ///         return value. The adapter is called with `recipient = this`,
    ///         the contract measures the buyToken balance delta itself,
    ///         enforces `delta >= minBuyAmount`, and forwards the measured
    ///         amount to the user's signed recipient. A malicious adapter
    ///         that keeps the sell asset and returns a non-zero but small
    ///         `buyAmount` cannot under-deliver — the measured-delta check
    ///         catches it.
    function relayCrossCurrency(
        IPrivacyPool.Withdrawal calldata _withdrawal,
        ProofLib.WithdrawProof calldata _proof,
        uint256 _scope
    ) external nonReentrant {
        FxPrivacyEntrypointStorage storage $ = _getFxStorage();
        IFxRouterSwapAdapter _adapter = $.swapAdapter;
        if (address(_adapter) == address(0)) revert SwapAdapterNotSet();

        if (_proof.withdrawnValue() == 0) revert InvalidWithdrawalAmount();
        if (_withdrawal.processooor != address(this)) revert InvalidProcessooor();

        IPrivacyPool _pool = scopeToPool[_scope];
        if (address(_pool) == address(0)) revert PoolNotFound();

        IERC20 _asset = IERC20(_pool.ASSET());
        if (!$.crossCurrencyEnabled[_asset]) revert CrossCurrencyDisabled(_asset);

        // Cross-currency bypasses the base relay() path, so enforce the
        // denomination gate here too (same lever, same source of truth).
        _enforceDenomination(_asset, _proof.withdrawnValue());

        uint256 _sellBalanceBefore = _asset.balanceOf(address(this));

        // Pool withdraws to address(this).
        _pool.withdraw(_withdrawal, _proof);

        CrossCurrencyRelayData memory _data = abi.decode(_withdrawal.data, (CrossCurrencyRelayData));

        if (_data.recipient == address(0)) revert ZeroRecipient();
        if (_data.buyToken == address(_asset)) revert BuyTokenEqualsAsset();
        if (_data.relayFeeBPS > assetConfig[_asset].maxRelayFeeBPS) revert RelayFeeGreaterThanMax();

        uint256 _withdrawnAmount = _proof.withdrawnValue();
        uint256 _amountAfterFee  = _deductFee(_withdrawnAmount, _data.relayFeeBPS);
        uint256 _feeAmount       = _withdrawnAmount - _amountAfterFee;

        // Pay relay fee to the keeper in the SELL asset (same shape as
        // vendored `relay()`).
        if (_feeAmount > 0) {
            _asset.safeTransfer(_data.feeRecipient, _feeAmount);
        }

        // Hand the rest to the swap adapter — recipient is THIS contract,
        // not the user. We trust nothing the adapter says and measure
        // delivery ourselves.
        IERC20 _buyToken = IERC20(_data.buyToken);
        uint256 _buyBalanceBefore = _buyToken.balanceOf(address(this));

        _asset.safeTransfer(address(_adapter), _amountAfterFee);
        // The adapter's own slippage gate (its minBuyAmount param) is
        // belt-and-suspenders; the canonical check is the measured delta
        // below.
        _adapter.swapExactInput(
            address(_asset),
            address(_buyToken),
            _amountAfterFee,
            _data.minBuyAmount,
            address(this)
        );

        uint256 _measuredOut = _buyToken.balanceOf(address(this)) - _buyBalanceBefore;
        if (_measuredOut < _data.minBuyAmount) {
            revert AdapterUnderdelivered(_measuredOut, _data.minBuyAmount);
        }

        // Codex-r2 MED #1: measure RECIPIENT-side delta on the final
        // transfer. A fee-on-transfer / deflationary `_buyToken` can tax
        // the egress and leave the recipient with less than `minBuyAmount`
        // even after the adapter delivered the gross amount to us.
        uint256 _recipientBefore = _buyToken.balanceOf(_data.recipient);
        _buyToken.safeTransfer(_data.recipient, _measuredOut);
        uint256 _recipientDelta = _buyToken.balanceOf(_data.recipient) - _recipientBefore;
        if (_recipientDelta < _data.minBuyAmount) {
            revert RecipientUnderdelivered(_recipientDelta, _data.minBuyAmount);
        }

        // Defense-in-depth: the entrypoint must not retain less of the
        // sell asset than before; that would imply the swap adapter pulled
        // from us beyond what we forwarded.
        uint256 _sellBalanceAfter = _asset.balanceOf(address(this));
        if (_sellBalanceBefore > _sellBalanceAfter) revert InvalidPoolState();

        emit CrossCurrencyRelayed(
            msg.sender,
            _data.recipient,
            _asset,
            _buyToken,
            _withdrawnAmount,
            _feeAmount,
            _recipientDelta
        );
    }
}
