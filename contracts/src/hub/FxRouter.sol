// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {IFxRouter} from "../interfaces/IFxRouter.sol";
import {FxRouterLib} from "../libraries/FxRouterLib.sol";

/// @title IFxRouterSwapAdapter
/// @notice Minimal adapter the Router calls to actually execute the swap.
///         The adapter is responsible for the Uniswap v4 unlock-callback
///         dance against `FxSwapHook`. Keeping it behind an interface lets
///         PR-5 land the signed-intent + Permit2 surface without bundling
///         the v4 callback wiring; PR-6 supplies the production adapter
///         that wraps `FxSwapHook` end-to-end.
/// @dev    Contract receives `sellAmountNet` of `sellToken` from the Router
///         BEFORE this call (Router uses `safeTransfer`). Adapter must
///         return at least `minBuyAmount` of `buyToken` to `recipient`
///         (typically the Router itself, which then forwards). Adapter
///         should revert if the realized buy amount falls below
///         `minBuyAmount`. The exact-input shape mirrors `FxSwapHook.
///         quoteExactInput`.
interface IFxRouterSwapAdapter {
    function swapExactInput(
        address sellToken,
        address buyToken,
        uint256 sellAmountNet,
        uint256 minBuyAmount,
        address recipient
    ) external returns (uint256 buyAmount);
}

/// @title FxRouter
/// @notice Signed-intent EIP-712 + Permit2 + SignatureChecker entry point on
///         top of `FxSwapHook` (via an injected `IFxRouterSwapAdapter`).
///         Implements `IFxRouter` (see `contracts/src/interfaces/IFxRouter.sol`).
///
/// ## PR-5 scope
///
/// * Pull `sellAmount` from `intent.taker` via Permit2 `permitTransferFrom`.
/// * Skim `protocolFee = (sellAmount * intent.feeBps) / BPS_DENOMINATOR` to
///   `treasury`.
/// * Forward the remainder to the configured swap adapter, which delivers
///   `buyToken` to `intent.recipient`.
/// * Enforce all validations + replay protection per spec.
///
/// PR-6 lands the production adapter (the v4 unlock+swap wrapper around
/// `FxSwapHook`) and swaps Ownable for an `AccessControl` + Timelock
/// admin model. Until then, Ownable gates `setTreasury` / `setMaxFeeBps` /
/// `setPairAllowed` / `setPaused` / `setSwapAdapter`.
///
/// ## Composition only — Constitutional rule (CLAUDE.md + SPEC_PHASE_3 §1)
///
/// No bespoke financial math, no oracle math, no AMM math. Math lives in
/// `FxRouterLib` (pure) + `FxSwapHook` (already audited surface). This
/// contract orchestrates auth, replay protection, fee skim, and routing.
///
/// Data flow:
///   signed FxIntent + Permit2 permit
///       |
///       v
///   FxRouter -- verify signature / replay / fees --> Permit2 + treasury
///       |
///       +-- sell token net amount -----------------> IFxRouterSwapAdapter
///       |
///       v
///   buy token delivered to signed recipient
contract FxRouter is IFxRouter, EIP712, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical Permit2 address (deterministic across chains).
    /// @dev    `0x000000000022D473030F116dDEE9F6B43aC78BA3` per Uniswap docs.
    ISignatureTransfer public immutable PERMIT2;

    /*//////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    address private _treasury;
    uint48  private _maxFeeBps;
    bool    private _paused;

    /// @notice The swap adapter the Router delegates exec to.
    /// @dev    Owner-settable so PR-6 can drop in the v4 wrapper without a
    ///         Router redeploy. Tests inject a deterministic mock.
    IFxRouterSwapAdapter public swapAdapter;

    /// @notice Allowed (sellToken, buyToken) pairs. One-way: allowing (A, B)
    ///         does NOT allow (B, A). Admin sets both directions as needed.
    mapping(address sellToken => mapping(address buyToken => bool allowed))
        private _pairAllowed;

    /// @notice Replay protection: taker → uuid → used.
    mapping(address taker => mapping(uint256 uuid => bool used))
        private _uuidUsed;

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    /// @param permit2_        Canonical Permit2 address. Pass the deterministic
    ///                        deployment on real chains; pass a deployed mock in tests.
    /// @param swapAdapter_    Initial swap adapter (PR-6 wrapper or test mock).
    /// @param treasury_       Initial fee sink.
    /// @param maxFeeBps_      Initial fee cap. Hard-capped by
    ///                        `FxRouterLib.MAX_FEE_BPS_HARD_CAP`.
    /// @param owner_          Initial Ownable owner (PR-6 hands this to a
    ///                        Compound Timelock).
    constructor(
        address permit2_,
        address swapAdapter_,
        address treasury_,
        uint48  maxFeeBps_,
        address owner_
    )
        EIP712("FxRouter", "1")
        Ownable(owner_)
    {
        if (permit2_ == address(0)) revert ZeroAddress();
        if (swapAdapter_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (maxFeeBps_ > FxRouterLib.MAX_FEE_BPS_HARD_CAP) {
            revert FeeBpsTooHigh(maxFeeBps_, FxRouterLib.MAX_FEE_BPS_HARD_CAP);
        }

        PERMIT2     = ISignatureTransfer(permit2_);
        swapAdapter = IFxRouterSwapAdapter(swapAdapter_);
        _treasury   = treasury_;
        _maxFeeBps  = maxFeeBps_;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS (impl-specific)
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error AdapterReturnedZero();

    /*//////////////////////////////////////////////////////////////
                                EVENTS (impl-specific)
    //////////////////////////////////////////////////////////////*/

    event SwapAdapterSet(address indexed adapter);

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFxRouter
    function executeIntent(
        FxRouterLib.FxIntent calldata intent,
        bytes calldata intentSig,
        bytes calldata permit,
        bytes calldata permitSig
    ) external nonReentrant returns (uint256 buyAmount) {
        // --- Validation order matches the PR-5 spec (PR brief §"Validations") ---

        if (_paused) revert RouterPaused();

        if (block.timestamp > intent.deadline) revert IntentExpired();

        uint256 maxAllowed = block.timestamp + FxRouterLib.MAX_DEADLINE_FUTURE;
        if (intent.deadline > maxAllowed) {
            revert IntentDeadlineTooFar(intent.deadline, maxAllowed);
        }

        if (intent.taker == address(0)) revert TakerZero();
        if (intent.recipient == address(0)) revert RecipientZero();

        if (intent.tenor != FxRouterLib.TENOR_INSTANT) {
            revert UnsupportedTenor(intent.tenor);
        }

        if (!_pairAllowed[intent.sellToken][intent.buyToken]) {
            revert UnsupportedPair(intent.sellToken, intent.buyToken);
        }

        if (intent.feeBps > _maxFeeBps) {
            revert FeeBpsTooHigh(intent.feeBps, _maxFeeBps);
        }

        // Decode Permit2 envelope and check the token/amount fields match the
        // intent BEFORE we burn gas on a sig-check.
        ISignatureTransfer.PermitTransferFrom memory permitDecoded =
            abi.decode(permit, (ISignatureTransfer.PermitTransferFrom));

        if (permitDecoded.permitted.token != intent.sellToken) {
            revert SellTokenMismatch(intent.sellToken, permitDecoded.permitted.token);
        }
        if (permitDecoded.permitted.amount != intent.sellAmount) {
            revert SellAmountMismatch(intent.sellAmount, permitDecoded.permitted.amount);
        }

        // EIP-712 digest: domain-separator-bound via OZ.
        bytes32 intentHash = _hashTypedDataV4(FxRouterLib.hashIntent(intent));

        if (!SignatureChecker.isValidSignatureNow(intent.taker, intentHash, intentSig)) {
            revert InvalidSignature();
        }

        if (_uuidUsed[intent.taker][intent.uuid]) revert UuidAlreadyUsed();
        _uuidUsed[intent.taker][intent.uuid] = true;

        // --- Pull sellToken to this Router via Permit2 ---
        PERMIT2.permitTransferFrom(
            permitDecoded,
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: intent.sellAmount
            }),
            intent.taker,
            permitSig
        );

        // --- Skim protocol fee ---
        uint256 protocolFee = FxRouterLib.computeFee(intent.sellAmount, intent.feeBps);
        if (protocolFee > 0) {
            IERC20(intent.sellToken).safeTransfer(_treasury, protocolFee);
            emit ProtocolFeeCollected(intent.sellToken, protocolFee);
        }

        // --- Forward net to adapter, which delivers buyToken to recipient ---
        uint256 sellAmountNet = intent.sellAmount - protocolFee;

        IERC20(intent.sellToken).safeTransfer(address(swapAdapter), sellAmountNet);
        buyAmount = swapAdapter.swapExactInput(
            intent.sellToken,
            intent.buyToken,
            sellAmountNet,
            intent.minBuyAmount,
            intent.recipient
        );

        if (buyAmount == 0) revert AdapterReturnedZero();
        if (buyAmount < intent.minBuyAmount) {
            revert InsufficientOutput(buyAmount, intent.minBuyAmount);
        }

        emit IntentExecuted(
            intentHash,
            intent.taker,
            intent.recipient,
            intent.sellToken,
            intent.sellAmount,
            intent.buyToken,
            buyAmount,
            protocolFee,
            intent.quoteId
        );
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFxRouter
    function hashIntent(FxRouterLib.FxIntent calldata intent)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(FxRouterLib.hashIntent(intent));
    }

    /// @inheritdoc IFxRouter
    function isIntentUuidUsed(address taker, uint256 uuid) external view returns (bool) {
        return _uuidUsed[taker][uuid];
    }

    /// @inheritdoc IFxRouter
    function isPairSupported(address sellToken, address buyToken) external view returns (bool) {
        return _pairAllowed[sellToken][buyToken];
    }

    /// @inheritdoc IFxRouter
    function treasury() external view returns (address) {
        return _treasury;
    }

    /// @inheritdoc IFxRouter
    function maxFeeBps() external view returns (uint48) {
        return _maxFeeBps;
    }

    /// @inheritdoc IFxRouter
    function paused() external view returns (bool) {
        return _paused;
    }

    /// @notice Exposes the EIP-712 domain separator for off-chain SDK builders.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFxRouter
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        _treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /// @inheritdoc IFxRouter
    function setMaxFeeBps(uint48 newMaxFeeBps) external onlyOwner {
        if (newMaxFeeBps > FxRouterLib.MAX_FEE_BPS_HARD_CAP) {
            revert FeeBpsTooHigh(newMaxFeeBps, FxRouterLib.MAX_FEE_BPS_HARD_CAP);
        }
        _maxFeeBps = newMaxFeeBps;
        emit MaxFeeBpsSet(newMaxFeeBps);
    }

    /// @inheritdoc IFxRouter
    function setPairAllowed(address sellToken, address buyToken, bool allowed) external onlyOwner {
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        _pairAllowed[sellToken][buyToken] = allowed;
        emit PairAllowedSet(sellToken, buyToken, allowed);
    }

    /// @inheritdoc IFxRouter
    function setPaused(bool isPaused) external onlyOwner {
        _paused = isPaused;
        emit PausedSet(isPaused);
    }

    /// @notice Update the swap adapter. PR-6 ships the production v4 wrapper;
    ///         until then this lets tests + ops swap implementations without
    ///         a Router redeploy.
    function setSwapAdapter(address newAdapter) external onlyOwner {
        if (newAdapter == address(0)) revert ZeroAddress();
        swapAdapter = IFxRouterSwapAdapter(newAdapter);
        emit SwapAdapterSet(newAdapter);
    }
}
