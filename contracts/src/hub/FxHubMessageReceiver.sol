// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFxHubMessageReceiver} from "../interfaces/IFxHubMessageReceiver.sol";
import {IMessageTransmitterV2} from "../interfaces/ICctp.sol";
import {CctpMessageLib} from "../libraries/CctpMessageLib.sol";

/// @title FxHubMessageReceiver
/// @notice Arc-side endpoint for cross-chain `FxSpoke` deposits.
///
/// Flow on each successful call to `executeDeposit`:
///   1. Verify CCTP message recipient == this contract
///   2. Call `MessageTransmitterV2.receiveMessage` → mints USDC to this contract
///   3. Verify the inner burn message hookData == abi.encode(beneficiary, hubCalldata)
///   4. Approve `FxMarketRegistry` for the minted amount
///   5. Forward the user-supplied `hubCalldata` to `FxMarketRegistry` via low-level call
///   6. On success: emit DepositExecuted
///   7. On revert: mark stranded (USDC stays at this contract for sweep)
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  spoke side                          hub side (this contract)   │
/// │  user → FxSpoke.enterHub             relayer → executeDeposit   │
/// │      │                                   │                       │
/// │      └─ depositForBurnWithHook ──────────┴─► receiveMessage      │
/// │             (hookData =                       │                  │
/// │              encode(beneficiary,              │                  │
/// │                     hubCalldata))             ▼                  │
/// │                                          (USDC minted to self)   │
/// │                                          decode hookData         │
/// │                                          assert match            │
/// │                                          approve FxMarketRegistry│
/// │                                          ┌──── try ─────┐        │
/// │                                          │ hubCalldata  │        │
/// │                                          └──── ok ──────┘        │
/// │                                          DepositExecuted         │
/// │                                          (on revert: Stranded)   │
/// └─────────────────────────────────────────────────────────────────┘
contract FxHubMessageReceiver is IFxHubMessageReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CctpMessageLib for bytes;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IMessageTransmitterV2 public immutable MESSAGE_TRANSMITTER;
    IERC20 public immutable USDC;
    address public immutable MARKET_REGISTRY;

    uint256 public constant STRANDED_DEPOSIT_GRACE = 24 hours;

    mapping(bytes32 messageNonce => StrandedDeposit) private _deposits;

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address messageTransmitter, address usdc, address marketRegistry) {
        if (messageTransmitter == address(0) || usdc == address(0) || marketRegistry == address(0)) {
            revert ZeroAddress();
        }
        MESSAGE_TRANSMITTER = IMessageTransmitterV2(messageTransmitter);
        USDC = IERC20(usdc);
        MARKET_REGISTRY = marketRegistry;
    }

    /*//////////////////////////////////////////////////////////////
                                READS
    //////////////////////////////////////////////////////////////*/

    function depositState(bytes32 messageNonce) external view returns (DepositState) {
        return _deposits[messageNonce].state;
    }

    function strandedDeposit(bytes32 messageNonce) external view returns (StrandedDeposit memory) {
        return _deposits[messageNonce];
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTE
    //////////////////////////////////////////////////////////////*/

    function executeDeposit(
        bytes calldata cctpMessage,
        bytes calldata cctpAttestation,
        address beneficiary,
        bytes calldata hubCalldata
    ) external nonReentrant {
        bytes32 nonce = cctpMessage.nonce();

        DepositState s = _deposits[nonce].state;
        if (s != DepositState.Unknown) revert AlreadyExecuted(nonce);

        // mintRecipient inside burn message body must equal this contract
        address mintRecipient = cctpMessage.mintRecipient();
        if (mintRecipient != address(this)) revert MintRecipientMismatch(address(this), mintRecipient);

        // hookData must equal abi.encode(beneficiary, hubCalldata) — binds spoke intent to hub action
        bytes memory expectedHook = abi.encode(beneficiary, hubCalldata);
        bytes memory hook = cctpMessage.hookData();
        if (keccak256(hook) != keccak256(expectedHook)) revert HookDataMismatch();

        uint256 expectedAmount = cctpMessage.mintedAmount();

        uint256 balBefore = USDC.balanceOf(address(this));
        MESSAGE_TRANSMITTER.receiveMessage(cctpMessage, cctpAttestation);
        uint256 balAfterMint = USDC.balanceOf(address(this));

        uint256 minted = balAfterMint - balBefore;
        if (minted != expectedAmount) revert AmountMismatch(expectedAmount, minted);

        // Approve the registry for EXACTLY the minted amount. Setting to
        // type(uint256).max (the prior behavior) would have let a malicious
        // hubCalldata pull leftover USDC from earlier stranded deposits;
        // a tight approval prevents the registry from touching anything
        // beyond this deposit's bridged funds.
        USDC.forceApprove(MARKET_REGISTRY, minted);

        (bool ok, bytes memory ret) = MARKET_REGISTRY.call(hubCalldata);

        // Always drop the approval — whether the call succeeded or reverted,
        // and whether or not the registry actually pulled anything.
        USDC.forceApprove(MARKET_REGISTRY, 0);

        // How much of THIS deposit's USDC is still parked on the receiver
        // after the registry call? `balBefore` is the receiver's baseline
        // (including any earlier stranded deposits); current balance above
        // baseline is this deposit's leftover.
        uint256 balPostCall = USDC.balanceOf(address(this));
        uint256 leftover = balPostCall > balBefore ? balPostCall - balBefore : 0;

        if (ok && leftover == 0) {
            // Fully consumed — registry pulled the entire `minted`.
            _deposits[nonce] = StrandedDeposit({
                beneficiary: beneficiary,
                amount: uint96(minted),
                strandedAt: 0,
                state: DepositState.Executed
            });
            emit DepositExecuted(nonce, beneficiary, minted);
        } else {
            // Either the call reverted OR it succeeded but didn't consume all
            // bridged USDC (e.g. a hubCalldata that supplies only 1 of 1000
            // bridged USDC, or returns success without touching the funds).
            // Codex adversarial-review #2: prior logic marked this Executed
            // and the leftover sat permanently unrecoverable. Now we mark
            // the unconsumed portion Stranded so the beneficiary can sweep
            // it after the grace window.
            uint96 stranded = ok ? uint96(leftover) : uint96(minted);
            _deposits[nonce] = StrandedDeposit({
                beneficiary: beneficiary,
                amount: stranded,
                strandedAt: uint64(block.timestamp),
                state: DepositState.Stranded
            });
            emit DepositStranded(nonce, beneficiary, stranded, ret);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                SWEEP
    //////////////////////////////////////////////////////////////*/

    function sweepStrandedDeposit(bytes32 messageNonce) external nonReentrant {
        StrandedDeposit memory d = _deposits[messageNonce];

        if (d.state == DepositState.Swept) revert AlreadySwept(messageNonce);
        if (d.state != DepositState.Stranded) revert NotStranded(messageNonce);

        uint256 graceEndsAt = uint256(d.strandedAt) + STRANDED_DEPOSIT_GRACE;
        if (block.timestamp < graceEndsAt) {
            revert GraceUnexpired(messageNonce, d.strandedAt, graceEndsAt);
        }

        _deposits[messageNonce].state = DepositState.Swept;

        USDC.safeTransfer(d.beneficiary, d.amount);
        emit DepositSwept(messageNonce, d.beneficiary, d.amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _ensureApproval(IERC20 token, address spender, uint256 needed) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current < needed) {
            if (current != 0) token.forceApprove(spender, 0);
            token.forceApprove(spender, type(uint256).max);
        }
    }
}
