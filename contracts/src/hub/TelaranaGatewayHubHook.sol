// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ICircleGatewayMinter} from "../interfaces/ICircleGateway.sol";
import {IHyperlaneRecipient} from "../interfaces/IHyperlane.sol";
import {ITelaranaGatewayHubHook} from "../interfaces/ITelaranaGatewayHubHook.sol";

/// @title TelaranaGatewayHubHook
/// @notice Destination-hub wrapper for Circle Gateway USDC mints.
///
/// Data flow:
///   1. Operator/user deposits USDC into Circle Gateway Wallet on source hub.
///   2. Source signer signs Circle Gateway BurnIntent offchain.
///   3. Circle Gateway API returns attestation payload + signature.
///   4. Executor calls receiveGatewayMint(attestation, signature, context).
///   5. This hook calls GatewayMinter.gatewayMint(...).
///   6. This hook verifies exact USDC balance delta and forwards USDC to the
///      configured destination hub/router.
///   7. Optional spot-FX request event is emitted for future execution layers.
contract TelaranaGatewayHubHook is
    ITelaranaGatewayHubHook,
    IHyperlaneRecipient,
    EIP712,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint8 public constant GATEWAY_CONTEXT_PROOF_VERSION = 1;
    bytes32 public constant GATEWAY_MINT_CONTEXT_TYPEHASH = keccak256(
        "GatewayMintContext(bytes32 routeId,bytes32 requestId,uint8 action,address sourceDepositor,address sourceSigner,address recipient,address tokenOut,uint256 amount,uint256 minAmountOut,bytes32 spotRouteId,bytes32 metadataRef)"
    );

    IERC20 public immutable USDC;
    ICircleGatewayMinter public immutable GATEWAY_MINTER;
    address public gatewayContextMailbox;

    mapping(bytes32 routeId => GatewayHubRoute route) private _gatewayRoutes;
    mapping(bytes32 requestId => GatewayReceipt receipt) private _gatewayReceipts;
    mapping(bytes32 routeId => GatewayContextProofMode mode) public gatewayContextProofMode;
    mapping(uint32 origin => mapping(bytes32 sender => bool trusted)) public gatewayContextTrustedSender;
    mapping(bytes32 requestId => bytes32 contextHash) public provenGatewayMintContextHash;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRoute(bytes32 routeId);
    error RouteDisabled(bytes32 routeId);
    error RouteMinterMismatch(address expected, address actual);
    error RouteTokenMismatch(address expected, address actual);
    error UnauthorizedRouteCaller(bytes32 routeId, address caller);
    error DuplicateRequest(bytes32 requestId);
    error RequestNotMinted(bytes32 requestId);
    error InvalidMintAmount(uint256 expected, uint256 actual);
    error InvalidSpotRequest();
    error SameGatewayDomain(uint32 domain);
    error UnexpectedHookData();
    error NotMailbox(address caller);
    error UntrustedGatewayContextSender(uint32 origin, bytes32 sender);
    error InvalidGatewayContextProof();
    error GatewayContextProofMissing(bytes32 requestId);
    error GatewayContextProofMismatch(bytes32 requestId, bytes32 expected, bytes32 actual);

    constructor(address usdc_, address gatewayMinter_, address initialAdmin) EIP712("TelaranaGatewayHubHook", "2") {
        if (usdc_ == address(0) || gatewayMinter_ == address(0) || initialAdmin == address(0)) {
            revert ZeroAddress();
        }

        USDC = IERC20(usdc_);
        GATEWAY_MINTER = ICircleGatewayMinter(gatewayMinter_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
        _grantRole(EXECUTOR_ROLE, initialAdmin);
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    function gatewayRoute(bytes32 routeId) external view returns (GatewayHubRoute memory route) {
        return _gatewayRoutes[routeId];
    }

    function gatewayRequestState(bytes32 requestId) external view returns (GatewayRequestState state) {
        return _gatewayReceipts[requestId].state;
    }

    function gatewayReceipt(bytes32 requestId) external view returns (GatewayReceipt memory receipt) {
        return _gatewayReceipts[requestId];
    }

    function setGatewayRoute(bytes32 routeId, GatewayHubRoute calldata route) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRoute(routeId, route);
        _gatewayRoutes[routeId] = route;

        emit GatewayHubRouteConfigured(
            routeId,
            route.sourceDomain,
            route.destinationDomain,
            route.sourceUsdc,
            route.destinationUsdc,
            route.sourceGatewayWallet,
            route.destinationGatewayMinter,
            route.signerMode,
            route.enabled,
            route.metadataRef
        );
    }

    function setGatewaySignerMode(bytes32 routeId, GatewaySignerMode signerMode, bool allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        GatewayHubRoute storage route = _gatewayRoutes[routeId];
        if (route.destinationGatewayMinter == address(0)) revert InvalidRoute(routeId);

        if (allowed) {
            route.signerMode = signerMode;
        } else if (route.signerMode == signerMode) {
            route.enabled = false;
        }

        emit GatewaySignerModeUpdated(routeId, signerMode, allowed);
    }

    function setGatewayContextProofMode(bytes32 routeId, GatewayContextProofMode mode)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        GatewayHubRoute storage route = _gatewayRoutes[routeId];
        if (route.destinationGatewayMinter == address(0)) revert InvalidRoute(routeId);
        gatewayContextProofMode[routeId] = mode;
        emit GatewayContextProofModeUpdated(routeId, mode);
    }

    function setGatewayContextMailbox(address mailbox) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gatewayContextMailbox = mailbox;
        emit GatewayContextMailboxSet(mailbox);
    }

    function setGatewayContextTrustedSender(uint32 origin, bytes32 sender, bool trusted)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (sender == bytes32(0)) revert ZeroAddress();
        gatewayContextTrustedSender[origin][sender] = trusted;
        emit GatewayContextTrustedSenderSet(origin, sender, trusted);
    }

    function handle(uint32 origin, bytes32 sender, bytes calldata messageBody) external payable whenNotPaused {
        if (msg.sender != gatewayContextMailbox) revert NotMailbox(msg.sender);
        if (!gatewayContextTrustedSender[origin][sender]) revert UntrustedGatewayContextSender(origin, sender);

        (uint8 version, bytes32 requestId, bytes32 routeId, bytes32 contextHash) =
            abi.decode(messageBody, (uint8, bytes32, bytes32, bytes32));
        if (version != GATEWAY_CONTEXT_PROOF_VERSION || requestId == bytes32(0) || contextHash == bytes32(0)) {
            revert InvalidGatewayContextProof();
        }

        provenGatewayMintContextHash[requestId] = contextHash;
        emit GatewayContextHashProven(requestId, routeId, origin, sender, contextHash);
    }

    function gatewayMintContextStructHash(GatewayMintContext calldata context) public pure returns (bytes32) {
        return _gatewayMintContextStructHash(context);
    }

    function gatewayMintContextDigest(GatewayMintContext calldata context) external view returns (bytes32) {
        return _hashTypedDataV4(_gatewayMintContextStructHash(context));
    }

    function receiveGatewayMint(
        bytes calldata attestationPayload,
        bytes calldata signature,
        GatewayMintContext calldata context
    ) external whenNotPaused nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256 amountReceived) {
        GatewayHubRoute memory route = _validatedRouteForMint(context);

        _gatewayReceipts[context.requestId].state = GatewayRequestState.MINTED;

        uint256 balanceBefore = USDC.balanceOf(address(this));
        GATEWAY_MINTER.gatewayMint(attestationPayload, signature);
        uint256 balanceAfter = USDC.balanceOf(address(this));

        amountReceived = balanceAfter - balanceBefore;
        if (amountReceived != context.amount) revert InvalidMintAmount(context.amount, amountReceived);

        _gatewayReceipts[context.requestId] = GatewayReceipt({
            routeId: context.routeId,
            state: GatewayRequestState.MINTED,
            action: context.action,
            sourceDepositor: context.sourceDepositor,
            sourceSigner: context.sourceSigner,
            recipient: context.recipient,
            tokenOut: context.tokenOut,
            amount: amountReceived,
            minAmountOut: context.minAmountOut,
            spotRouteId: context.spotRouteId,
            metadataRef: context.metadataRef
        });

        if (route.destinationHub != address(this)) {
            USDC.safeTransfer(route.destinationHub, amountReceived);
        }

        emit GatewayHubMintAttested(
            context.requestId, context.routeId, address(GATEWAY_MINTER), keccak256(attestationPayload)
        );
        emit GatewayHubLiquidityReceived(
            context.requestId, context.routeId, context.recipient, address(USDC), amountReceived
        );

        if (context.action == GatewayHubAction.MINT_AND_REQUEST_SPOT_FX) {
            emit GatewayAtomicFxSwapRequested(
                context.requestId,
                context.routeId,
                context.spotRouteId,
                context.tokenOut,
                amountReceived,
                context.minAmountOut,
                context.recipient,
                context.metadataRef
            );
        }
    }

    function markGatewayAtomicFxSwapSettled(bytes32 requestId, uint256 amountOut) external onlyRole(EXECUTOR_ROLE) {
        GatewayReceipt storage receipt = _gatewayReceipts[requestId];
        if (receipt.state != GatewayRequestState.MINTED) revert RequestNotMinted(requestId);
        if (receipt.action != GatewayHubAction.MINT_AND_REQUEST_SPOT_FX) revert InvalidSpotRequest();

        receipt.state = GatewayRequestState.SETTLED;

        emit GatewayAtomicFxSwapSettled(requestId, receipt.spotRouteId, receipt.recipient, receipt.tokenOut, amountOut);
    }

    function _validatedRouteForMint(GatewayMintContext calldata context)
        internal
        view
        returns (GatewayHubRoute memory route)
    {
        if (context.requestId == bytes32(0) || context.routeId == bytes32(0)) revert InvalidRoute(context.routeId);
        if (_gatewayReceipts[context.requestId].state != GatewayRequestState.UNKNOWN) {
            revert DuplicateRequest(context.requestId);
        }
        if (context.amount == 0) revert ZeroAmount();
        if (
            context.sourceDepositor == address(0) || context.sourceSigner == address(0)
                || context.recipient == address(0)
        ) {
            revert ZeroAddress();
        }

        route = _gatewayRoutes[context.routeId];
        if (route.destinationGatewayMinter == address(0)) revert InvalidRoute(context.routeId);
        if (!route.enabled) revert RouteDisabled(context.routeId);
        if (route.destinationGatewayMinter != address(GATEWAY_MINTER)) {
            revert RouteMinterMismatch(address(GATEWAY_MINTER), route.destinationGatewayMinter);
        }
        if (route.destinationUsdc != address(USDC)) {
            revert RouteTokenMismatch(address(USDC), route.destinationUsdc);
        }
        if (
            route.destinationHub == address(0) || route.sourceUsdc == address(0)
                || route.sourceGatewayWallet == address(0)
        ) {
            revert ZeroAddress();
        }
        if (route.whitelistedCaller != address(0) && msg.sender != route.whitelistedCaller) {
            revert UnauthorizedRouteCaller(context.routeId, msg.sender);
        }

        if (uint8(context.action) > uint8(GatewayHubAction.MINT_AND_REQUEST_SPOT_FX)) {
            revert InvalidSpotRequest();
        } else if (context.action == GatewayHubAction.MINT_TO_HUB) {
            if (context.tokenOut != address(0) || context.spotRouteId != bytes32(0) || context.minAmountOut != 0) {
                revert InvalidSpotRequest();
            }
        } else if (context.action == GatewayHubAction.MINT_AND_REQUEST_SPOT_FX) {
            if (context.tokenOut == address(0) || context.spotRouteId == bytes32(0) || context.minAmountOut == 0) {
                revert InvalidSpotRequest();
            }
        }

        _verifyGatewayContextProof(context);
    }

    function _validateRoute(bytes32 routeId, GatewayHubRoute calldata route) internal view {
        if (routeId == bytes32(0)) revert InvalidRoute(routeId);
        if (route.sourceDomain == route.destinationDomain) revert SameGatewayDomain(route.sourceDomain);
        if (
            route.sourceUsdc == address(0) || route.destinationUsdc == address(0)
                || route.sourceGatewayWallet == address(0) || route.destinationGatewayMinter == address(0)
                || route.destinationHub == address(0)
        ) {
            revert ZeroAddress();
        }
        if (route.destinationGatewayMinter != address(GATEWAY_MINTER)) {
            revert RouteMinterMismatch(address(GATEWAY_MINTER), route.destinationGatewayMinter);
        }
        if (route.destinationUsdc != address(USDC)) {
            revert RouteTokenMismatch(address(USDC), route.destinationUsdc);
        }
    }

    function _verifyGatewayContextProof(GatewayMintContext calldata context) internal view {
        GatewayContextProofMode mode = gatewayContextProofMode[context.routeId];
        if (mode == GatewayContextProofMode.NONE) {
            if (context.hookData.length != 0) revert UnexpectedHookData();
            return;
        }

        bytes32 structHash = _gatewayMintContextStructHash(context);
        bytes32 provenHash = provenGatewayMintContextHash[context.requestId];
        bool hyperlaneProven = provenHash == structHash;

        if (mode == GatewayContextProofMode.SIGNED_INTENT) {
            if (!_hasValidSignedIntent(context, structHash)) revert GatewayContextProofMissing(context.requestId);
        } else if (mode == GatewayContextProofMode.HYPERLANE) {
            if (context.hookData.length != 0) revert UnexpectedHookData();
            if (!hyperlaneProven) {
                revert GatewayContextProofMismatch(context.requestId, structHash, provenHash);
            }
        } else if (mode == GatewayContextProofMode.SIGNED_INTENT_OR_HYPERLANE) {
            if (hyperlaneProven) return;
            if (_hasValidSignedIntent(context, structHash)) return;
            if (provenHash != bytes32(0)) {
                revert GatewayContextProofMismatch(context.requestId, structHash, provenHash);
            }
            revert GatewayContextProofMissing(context.requestId);
        } else {
            revert InvalidGatewayContextProof();
        }
    }

    function _hasValidSignedIntent(GatewayMintContext calldata context, bytes32 structHash)
        internal
        view
        returns (bool)
    {
        if (context.hookData.length == 0) return false;
        GatewayContextProof memory proof = abi.decode(context.hookData, (GatewayContextProof));
        if (proof.version != GATEWAY_CONTEXT_PROOF_VERSION || proof.sourceDepositorSignature.length == 0) {
            revert InvalidGatewayContextProof();
        }
        bytes32 digest = _hashTypedDataV4(structHash);
        return SignatureChecker.isValidSignatureNow(context.sourceDepositor, digest, proof.sourceDepositorSignature);
    }

    function _gatewayMintContextStructHash(GatewayMintContext calldata context) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                GATEWAY_MINT_CONTEXT_TYPEHASH,
                context.routeId,
                context.requestId,
                uint8(context.action),
                context.sourceDepositor,
                context.sourceSigner,
                context.recipient,
                context.tokenOut,
                context.amount,
                context.minAmountOut,
                context.spotRouteId,
                context.metadataRef
            )
        );
    }
}
