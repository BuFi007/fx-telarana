// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IGatewayWallet, IGatewayMinter} from "../interfaces/IGateway.sol";

/// @title FxGatewayHook
///
/// @notice Hub-side bridge for cross-hub USDC liquidity via Circle Gateway.
///         Deployed on each Telaraña hub chain (Fuji, Arc, …). Lets the local hub:
///           - LOCK USDC into Gateway so an authorized signer can later burn it for a remote mint
///           - MINT USDC on this chain from an attestation Circle issued for a remote burn
///
/// @dev Architectural role:
///   Spokes use CCTP V2 for user deposits → primary hub (Fuji). The PRIMARY HUB is where users
///   ever interact. Gateway is the PROTOCOL-LEVEL bridge that moves USDC liquidity between hubs
///   (Fuji ↔ Arc) for FX trading and perp execution venues; never user-initiated.
///
/// @dev Trust model:
///   Only the local hub (`HUB`) can call `lockForRemote` / `mintFromRemote` / `setAuthority`.
///   Circle's BurnIntent signature flow runs off-chain: the `authority` we set here is who
///   signs the BurnIntent that authorizes USDC to leave Gateway on this chain. For now this
///   is an EOA we control; post-EIP-1271-on-Gateway (Circle's mid-July ETA) it becomes the
///   hub contract itself via `isValidSignature`. The on-chain code is unchanged — only the
///   constructor arg / `setAuthority` target differs.
///
/// @dev Atomicity:
///   Gateway burn is instant; mint on dest happens after Circle's attestation service signs
///   (~500ms). The hook is "protocol-atomic" not "tx-atomic": the V4 swap hook coordinates
///   in-flight state. If the destination mint doesn't land before the swap's grace window
///   closes, the source-side hub flags the deposit as in-flight and the user's swap reverts
///   cleanly (no half-state).
///
/// ┌────────────────────────────────────────────────────────────────────────────┐
/// │  source hub (e.g. Fuji)                  destination hub (e.g. Arc)        │
/// │  HUB.gatewayBridge ──lockForRemote──┐    HUB.gatewayBridge ──mintFromRemote┤
/// │                                     │                              │       │
/// │            ┌────────────────────────┴────┐                         │       │
/// │            │ GatewayWallet.depositFor    │                         │       │
/// │            │   (token=USDC,              │                         │       │
/// │            │    depositor=authority,     │                         │       │
/// │            │    value=amount)            │                         │       │
/// │            └─────────────────────────────┘                         │       │
/// │                       │                                            │       │
/// │           (off-chain) │ authority signs BurnIntent for this lock   │       │
/// │                       ▼                                            │       │
/// │           Circle operator validates + signs attestation            │       │
/// │                       │                                            │       │
/// │                       └────────────────────────────────────────────►       │
/// │                                                  GatewayMinter.gatewayMint │
/// │                                                  (destRecipient = this)    │
/// │                                                  → USDC minted to hook     │
/// │                                                  → forwarded to HUB        │
/// └────────────────────────────────────────────────────────────────────────────┘
contract FxGatewayHook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IERC20  public immutable USDC;
    address public immutable GATEWAY_WALLET;
    address public immutable GATEWAY_MINTER;
    address public immutable HUB;
    uint32  public immutable LOCAL_DOMAIN;

    /// @notice Address whose Gateway-balance is used for cross-hub transfers. Signs BurnIntents
    /// off-chain. Mutable so we can rotate EOA → hub-contract once Circle's 1271 support ships.
    address public authority;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event LockedForRemote(uint256 amount, address indexed authority);
    event MintedFromRemote(uint256 amount, address indexed forwardedTo);
    event AuthorityRotated(address indexed previousAuthority, address indexed newAuthority);
    event GatewayWithdrawalInitiated(uint256 amount);
    event GatewayWithdrawalCompleted(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotHub(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error NoMintReceived();
    error AuthorityNotHook(address authority);

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address usdc,
        address gatewayWallet,
        address gatewayMinter,
        address hub,
        uint32  localDomain,
        address initialAuthority
    ) {
        if (
            usdc == address(0) ||
            gatewayWallet == address(0) ||
            gatewayMinter == address(0) ||
            hub == address(0) ||
            initialAuthority == address(0)
        ) revert ZeroAddress();

        USDC           = IERC20(usdc);
        GATEWAY_WALLET = gatewayWallet;
        GATEWAY_MINTER = gatewayMinter;
        HUB            = hub;
        LOCAL_DOMAIN   = localDomain;
        authority      = initialAuthority;
    }

    /*//////////////////////////////////////////////////////////////
                                ACCESS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHub() {
        if (msg.sender != HUB) revert NotHub(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                SOURCE SIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Locks USDC into Circle Gateway under `authority`'s balance. The authority later
    /// signs a BurnIntent off-chain naming a destination hub; Circle's operator issues an
    /// attestation; the destination hub calls `mintFromRemote` with that attestation.
    ///
    /// @dev The hub must have approved this contract for `amount` USDC before calling.
    function lockForRemote(uint256 amount) external onlyHub nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Pull USDC from the hub
        USDC.safeTransferFrom(HUB, address(this), amount);

        // Approve Gateway for exactly this amount, then deposit-for our authority
        USDC.forceApprove(GATEWAY_WALLET, amount);
        IGatewayWallet(GATEWAY_WALLET).depositFor(address(USDC), authority, amount);

        // Drop the approval if any dust remained (depositFor should consume it all, but be
        // defensive — same pattern as FxHubMessageReceiver after a registry call)
        USDC.forceApprove(GATEWAY_WALLET, 0);

        emit LockedForRemote(amount, authority);
    }

    /*//////////////////////////////////////////////////////////////
                                DEST SIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints USDC on this chain from a Circle attestation, forwarding the proceeds to
    /// the local hub.
    ///
    /// @dev The BurnIntent that generated this attestation MUST have:
    ///   - `destinationCaller` set to this contract (otherwise the GatewayMinter will reject
    ///     mints from anyone else, but a malicious relayer could front-run us; setting the
    ///     caller explicitly locks the mint to this hook)
    ///   - `destinationRecipient` set to this contract (so the minted USDC lands here and we
    ///     can deterministically forward it; addressing the hub directly would skip the
    ///     forward step but lose post-mint hook semantics)
    ///   - `destinationContract` set to GATEWAY_MINTER (enforced by Circle in their
    ///     validation)
    ///
    /// @dev Measures the actual minted amount via balance delta — never trusts the
    /// attestation's `value` field directly, since the GatewayMinter could revert silently
    /// for a denylisted token or expired spec.
    function mintFromRemote(bytes calldata attestationPayload, bytes calldata signature)
        external
        onlyHub
        nonReentrant
        returns (uint256 minted)
    {
        uint256 balBefore = USDC.balanceOf(address(this));

        IGatewayMinter(GATEWAY_MINTER).gatewayMint(attestationPayload, signature);

        uint256 balAfter = USDC.balanceOf(address(this));
        minted = balAfter - balBefore;
        if (minted == 0) revert NoMintReceived();

        // Forward proceeds to the hub
        USDC.safeTransfer(HUB, minted);

        emit MintedFromRemote(minted, HUB);
    }

    /*//////////////////////////////////////////////////////////////
                                GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Rotates the BurnIntent-signing authority. Used to migrate from
    /// EOA-signing → contract-1271-signing once Circle's Gateway supports it (mid-July 2026).
    ///
    /// @dev Existing balance still locked under the OLD authority must be withdrawn separately
    /// via `initiateGatewayWithdrawal` → wait operator delay → `completeGatewayWithdrawal`,
    /// then re-locked under the new authority. This function does NOT migrate balance.
    function setAuthority(address newAuthority) external onlyHub {
        if (newAuthority == address(0)) revert ZeroAddress();
        address old = authority;
        authority = newAuthority;
        emit AuthorityRotated(old, newAuthority);
    }

    /// @notice Initiates a withdrawal of USDC from Gateway back to this hook contract. The
    /// GatewayWallet enforces an operator-set delay before `completeGatewayWithdrawal` works.
    ///
    /// @dev Only operates when `authority == address(this)` — i.e. post-EIP-1271 rotation
    /// when this hook itself is the Gateway depositor. Pre-rotation the depositor is an EOA,
    /// `GatewayWallet.initiateWithdrawal` would key off `msg.sender == hook` (zero balance)
    /// and silently no-op; the EOA must withdraw out-of-band per the runbook in
    /// `docs/INCIDENT_RESPONSE.md`. Codex adversarial-review v3 finding #2.
    function initiateGatewayWithdrawal(uint256 amount) external onlyHub {
        if (amount == 0) revert ZeroAmount();
        if (authority != address(this)) revert AuthorityNotHook(authority);
        IGatewayWallet(GATEWAY_WALLET).initiateWithdrawal(address(USDC), amount);
        emit GatewayWithdrawalInitiated(amount);
    }

    /// @notice Completes a previously-initiated withdrawal once the operator delay has passed.
    /// Pulls the USDC into this hook and forwards it to the hub.
    ///
    /// @dev Same authority-binding constraint as `initiateGatewayWithdrawal`. See finding #2.
    function completeGatewayWithdrawal() external onlyHub nonReentrant {
        if (authority != address(this)) revert AuthorityNotHook(authority);
        uint256 balBefore = USDC.balanceOf(address(this));
        IGatewayWallet(GATEWAY_WALLET).withdraw(address(USDC));
        uint256 balAfter = USDC.balanceOf(address(this));

        uint256 received = balAfter - balBefore;
        if (received > 0) {
            USDC.safeTransfer(HUB, received);
        }
        emit GatewayWithdrawalCompleted(received);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC currently locked in Gateway under our authority on this chain.
    function gatewayBalance() external view returns (uint256) {
        return IGatewayWallet(GATEWAY_WALLET).availableBalance(address(USDC), authority);
    }

    /// @notice Block at which an in-progress withdrawal becomes withdrawable, if any.
    function gatewayWithdrawalUnlockBlock() external view returns (uint256) {
        return IGatewayWallet(GATEWAY_WALLET).withdrawalBlock(address(USDC), authority);
    }
}
