// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {FxRouterLib} from "../libraries/FxRouterLib.sol";

/// @title IFxRouter
/// @notice Signed-intent EIP-712 + Permit2 + SignatureChecker entry point on
///         top of `FxSwapHook`. Schema-aligned with Circle StableFX so a single
///         client envelope can be routed to either rail by Pasillo / aggregators.
///
/// @dev    Spec: `docs/SPEC_FX_ROUTER_AND_PASILLO_QUOTE_API.md`.
///         This interface is the implementation contract; struct + typehash +
///         hash helpers live in `FxRouterLib`. The `FxRouter.sol` contract that
///         implements this is built by the Phase 2.6R implementing agent — this
///         file exists so the SDK + downstream contracts have a compile-target
///         on day one.
interface IFxRouter {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error IntentExpired();
    error IntentDeadlineTooFar(uint256 deadline, uint256 maxAllowed);
    error InvalidSignature();
    error UuidAlreadyUsed();
    error UnsupportedTenor(uint8 tenor);
    error UnsupportedPair(address sellToken, address buyToken);
    error SellAmountMismatch(uint256 intentAmount, uint256 permitAmount);
    error SellTokenMismatch(address intentToken, address permitToken);
    error InsufficientOutput(uint256 received, uint256 minRequired);
    error RecipientZero();
    error TakerZero();
    error FeeBpsTooHigh(uint48 feeBps, uint48 maxFeeBps);
    error RouterPaused();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Single canonical execution event. Indexer-friendly: every interesting
    ///         field is in one log so Pasillo / others can reconcile against off-chain
    ///         quote books with a single subscription.
    event IntentExecuted(
        bytes32 indexed intentHash,
        address indexed taker,
        address indexed recipient,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint256 protocolFee,
        bytes32 quoteId
    );

    event ProtocolFeeCollected(address indexed token, uint256 amount);
    event PausedSet(bool paused);
    event TreasurySet(address indexed treasury);
    event MaxFeeBpsSet(uint48 maxFeeBps);
    event PairAllowedSet(address indexed sellToken, address indexed buyToken, bool allowed);

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a signed FxIntent: pull sellToken via Permit2, swap via
    ///         FxSwapHook, deliver buyToken to intent.recipient, skim fee to treasury.
    /// @param intent      User-signed FxIntent envelope.
    /// @param intentSig   ECDSA (65 bytes) OR EIP-1271 / EIP-7702 sig over the EIP-712 digest.
    /// @param permit      Permit2 PermitTransferFrom matching intent.sellToken + intent.sellAmount.
    /// @param permitSig   Permit2 signature.
    /// @return buyAmount  Actual buyToken delivered to recipient (post-fee, post-AMM).
    function executeIntent(
        FxRouterLib.FxIntent calldata intent,
        bytes calldata intentSig,
        bytes calldata permit,        // ABI-encoded IPermit2.PermitTransferFrom — abi'd as bytes to keep
                                      // this interface independent of the Permit2 import path
        bytes calldata permitSig
    ) external returns (uint256 buyAmount);

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the EIP-712 digest for an intent (domain-separator-bound).
    ///         SDK uses this for client-side verification of the envelope it built.
    function hashIntent(FxRouterLib.FxIntent calldata intent) external view returns (bytes32);

    function isIntentUuidUsed(address taker, uint256 uuid) external view returns (bool);

    function isPairSupported(address sellToken, address buyToken) external view returns (bool);

    function treasury() external view returns (address);
    function maxFeeBps() external view returns (uint48);
    function paused() external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                              ADMIN (timelock)
    //////////////////////////////////////////////////////////////*/

    function setTreasury(address newTreasury) external;
    function setMaxFeeBps(uint48 newMaxFeeBps) external;
    function setPairAllowed(address sellToken, address buyToken, bool allowed) external;
    function setPaused(bool isPaused) external;
}
