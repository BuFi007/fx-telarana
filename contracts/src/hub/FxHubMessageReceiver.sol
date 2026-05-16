// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFxHubMessageReceiver} from "../interfaces/IFxHubMessageReceiver.sol";
import {IFxGatewayHook} from "../interfaces/IFxGatewayHook.sol";
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

    // ── Stage 6: Gateway-relay surface ───────────────────────────────────
    // The hub is the only caller the FxGatewayHook accepts (its `onlyHub`
    // modifier is gated on this contract's immutable address). This block
    // lets the hub *delegate* that authority to a whitelist of approved
    // relayers (e.g. BUFX's spot/perp contracts) without giving them
    // direct hook access. The hub stays the protocol's state-machine
    // owner; relayers just trigger cross-hub liquidity moves.
    address public owner;
    address public gatewayHook;
    mapping(address relayer => bool allowed) public relayCallers;

    error NotOwner(address caller);
    error NotAuthorizedRelayer(address caller);
    error ZeroAmount();
    error GatewayHookNotSet();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GatewayHookChanged(address indexed previousHook, address indexed newHook);
    event RelayCallerSet(address indexed relayer, bool allowed);
    event RelayedToRemoteHub(address indexed relayer, uint256 amount, address indexed hook);
    event RelayedMintFromRemote(address indexed relayer, uint256 minted, address indexed hook);

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address messageTransmitter,
        address usdc,
        address marketRegistry,
        address initialOwner
    ) {
        if (
            messageTransmitter == address(0) ||
            usdc == address(0) ||
            marketRegistry == address(0) ||
            initialOwner == address(0)
        ) {
            revert ZeroAddress();
        }
        MESSAGE_TRANSMITTER = IMessageTransmitterV2(messageTransmitter);
        USDC = IERC20(usdc);
        MARKET_REGISTRY = marketRegistry;
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /*//////////////////////////////////////////////////////////////
                                STAGE 6 — RELAY
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyAuthorizedRelayer() {
        if (msg.sender != owner && !relayCallers[msg.sender]) {
            revert NotAuthorizedRelayer(msg.sender);
        }
        _;
    }

    /// @notice Transfer hub ownership (used to rotate from deployer EOA to a
    /// TimelockController / DAO multisig in production).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    /// @notice Wire (or rewire) the FxGatewayHook this hub talks to for
    /// cross-hub USDC moves. Set once after deploy; rotated only on hook
    /// redeploy (e.g. EIP-1271 authority migration mid-July 2026).
    function setGatewayHook(address newHook) external onlyOwner {
        if (newHook == address(0)) revert ZeroAddress();
        address previous = gatewayHook;
        gatewayHook = newHook;
        emit GatewayHookChanged(previous, newHook);
    }

    /// @notice Add / remove a relayer (e.g. BUFX spot/perp contract) that may
    /// trigger Gateway moves through this hub. Permission is scoped to
    /// `relayToRemoteHub` + `relayMintFromRemote` — never gives the relayer
    /// the rest of the hub surface.
    function setRelayCaller(address relayer, bool allowed) external onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        relayCallers[relayer] = allowed;
        emit RelayCallerSet(relayer, allowed);
    }

    /// @notice Lock USDC for a cross-hub move. Pulls `amount` USDC from the
    /// caller (must have approved this hub), forwards it to the local
    /// FxGatewayHook, and triggers `lockForRemote` so an off-chain authority
    /// can sign a BurnIntent.
    ///
    /// @dev Only callable by `owner` or whitelisted `relayCallers`. This hub
    /// contract is the `HUB` immutable on the hook, so its call passes the
    /// hook's `onlyHub` modifier.
    function relayToRemoteHub(uint256 amount) external onlyAuthorizedRelayer nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (gatewayHook == address(0)) revert GatewayHookNotSet();

        // Pull USDC from the relayer into this hub
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        // Approve the hook (tight allowance) so its safeTransferFrom in lockForRemote works
        USDC.forceApprove(gatewayHook, amount);

        IFxGatewayHook(gatewayHook).lockForRemote(amount);

        // Always drop the approval — same defensive pattern as executeDeposit
        USDC.forceApprove(gatewayHook, 0);

        emit RelayedToRemoteHub(msg.sender, amount, gatewayHook);
    }

    /// @notice Mint USDC from a remote Gateway BurnIntent attestation. The
    /// hook receives the minted USDC and forwards it back to this hub via
    /// `mintFromRemote`'s post-mint transfer.
    function relayMintFromRemote(bytes calldata attestationPayload, bytes calldata signature)
        external
        onlyAuthorizedRelayer
        nonReentrant
        returns (uint256 minted)
    {
        if (gatewayHook == address(0)) revert GatewayHookNotSet();
        minted = IFxGatewayHook(gatewayHook).mintFromRemote(attestationPayload, signature);
        emit RelayedMintFromRemote(msg.sender, minted, gatewayHook);
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
