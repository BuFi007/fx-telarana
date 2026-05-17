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
///         Storage layout NOTE: the vendored Entrypoint is UUPS-upgradeable
///         and treats its declared slots as fixed. All new state on this
///         child contract is APPENDED — never insert above. A `__gap`
///         reserves future-upgrade slots.
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

    /*//////////////////////////////////////////////////////////////
                                STATE (APPEND-ONLY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap adapter wrapping `FxSwapHook` (or any IFxRouterSwapAdapter).
    ///         Owner-settable; PR-6 wires the production v4-unlock adapter
    ///         here; tests inject `MockSwapAdapter`.
    IFxRouterSwapAdapter public swapAdapter;

    /// @notice Per-asset opt-in flag for cross-currency relays. Set by owner
    ///         once a stable swap pool exists for the asset; until then the
    ///         asset is shielded-only.
    mapping(IERC20 _asset => bool _enabled) public crossCurrencyEnabled;

    /// @dev Reserved for future state. Always leave the *last* declared
    ///      slot a `__gap` array to keep upgrades safe.
    uint256[48] private __gap;

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
    error AdapterReturnedZero();

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Wire (or rotate) the swap adapter. Owner-gated via the
    ///         vendored OZ AccessControl `_OWNER_ROLE`.
    function setSwapAdapter(IFxRouterSwapAdapter _newAdapter) external onlyRole(_OWNER_ROLE) {
        if (address(_newAdapter) == address(0)) revert ZeroAddress();
        emit SwapAdapterSet(address(swapAdapter), address(_newAdapter));
        swapAdapter = _newAdapter;
    }

    /// @notice Toggle cross-currency relays per asset. Off by default;
    ///         owner flips on once a swap adapter + LP exist for the asset.
    function setCrossCurrencyEnabled(IERC20 _asset, bool _enabled) external onlyRole(_OWNER_ROLE) {
        if (address(_asset) == address(0)) revert ZeroAddress();
        crossCurrencyEnabled[_asset] = _enabled;
        emit CrossCurrencyEnabled(_asset, _enabled);
    }

    /*//////////////////////////////////////////////////////////////
                        CROSS-CURRENCY RELAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Process a shielded withdrawal and atomically swap the output
    ///         into a different currency before delivering to the recipient.
    /// @dev    `_withdrawal.data` must decode as `CrossCurrencyRelayData`.
    ///         The Groth16 proof's `context` binds the user's intent over
    ///         the full data blob (buyToken + minBuyAmount included), so the
    ///         swap target and slippage bound are non-malleable.
    function relayCrossCurrency(
        IPrivacyPool.Withdrawal calldata _withdrawal,
        ProofLib.WithdrawProof calldata _proof,
        uint256 _scope
    ) external nonReentrant {
        if (address(swapAdapter) == address(0)) revert SwapAdapterNotSet();
        if (_proof.withdrawnValue() == 0) revert InvalidWithdrawalAmount();
        if (_withdrawal.processooor != address(this)) revert InvalidProcessooor();

        IPrivacyPool _pool = scopeToPool[_scope];
        if (address(_pool) == address(0)) revert PoolNotFound();

        IERC20 _asset = IERC20(_pool.ASSET());
        if (!crossCurrencyEnabled[_asset]) revert CrossCurrencyDisabled(_asset);

        uint256 _balanceBefore = _asset.balanceOf(address(this));

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

        // Hand the rest to the swap adapter, which delivers buyToken to
        // the recipient. Adapter must revert on slippage; we additionally
        // assert non-zero output.
        _asset.safeTransfer(address(swapAdapter), _amountAfterFee);
        uint256 _buyAmount = swapAdapter.swapExactInput(
            address(_asset),
            _data.buyToken,
            _amountAfterFee,
            _data.minBuyAmount,
            _data.recipient
        );
        if (_buyAmount == 0) revert AdapterReturnedZero();

        // Defense-in-depth: the entrypoint must not retain less of the
        // sell asset than before; that would imply the swap adapter pulled
        // from us beyond what we forwarded.
        uint256 _balanceAfter = _asset.balanceOf(address(this));
        if (_balanceBefore > _balanceAfter) revert InvalidPoolState();

        emit CrossCurrencyRelayed(
            msg.sender,
            _data.recipient,
            _asset,
            IERC20(_data.buyToken),
            _withdrawnAmount,
            _feeAmount,
            _buyAmount
        );
    }
}
