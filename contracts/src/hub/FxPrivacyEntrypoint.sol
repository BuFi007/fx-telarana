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

        uint256 _sellBalanceBefore = _asset.balanceOf(address(this));

        // Pool withdraws to address(this).
        _pool.withdraw(_withdrawal, _proof);

        CrossCurrencyRelayData memory _data = abi.decode(_withdrawal.data, (CrossCurrencyRelayData));

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

        _buyToken.safeTransfer(_data.recipient, _measuredOut);

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
            _measuredOut
        );
    }
}
