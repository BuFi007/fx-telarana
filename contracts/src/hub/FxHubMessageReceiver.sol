// SPDX-License-Identifier: MIT
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
        uint256 balAfter = USDC.balanceOf(address(this));

        uint256 minted = balAfter - balBefore;
        if (minted != expectedAmount) revert AmountMismatch(expectedAmount, minted);

        // Forward to FxMarketRegistry. Approval is reset on a per-call basis to avoid
        // residual allowance if the call reverts.
        _ensureApproval(USDC, MARKET_REGISTRY, minted);

        (bool ok, bytes memory ret) = MARKET_REGISTRY.call(hubCalldata);

        if (ok) {
            _deposits[nonce] = StrandedDeposit({
                beneficiary: beneficiary,
                amount: uint96(minted),
                strandedAt: 0,
                state: DepositState.Executed
            });
            emit DepositExecuted(nonce, beneficiary, minted);
        } else {
            // Mark stranded; reset registry approval; USDC stays here until sweep.
            USDC.forceApprove(MARKET_REGISTRY, 0);
            _deposits[nonce] = StrandedDeposit({
                beneficiary: beneficiary,
                amount: uint96(minted),
                strandedAt: uint64(block.timestamp),
                state: DepositState.Stranded
            });
            emit DepositStranded(nonce, beneficiary, minted, ret);
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
