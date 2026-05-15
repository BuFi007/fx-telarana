// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICircleGatewayMinter} from "../interfaces/ICircleGateway.sol";
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
contract TelaranaGatewayHubHook is ITelaranaGatewayHubHook, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    IERC20 public immutable USDC;
    ICircleGatewayMinter public immutable GATEWAY_MINTER;

    mapping(bytes32 routeId => GatewayHubRoute route) private _gatewayRoutes;
    mapping(bytes32 requestId => GatewayReceipt receipt) private _gatewayReceipts;

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
    error InsufficientGatewayAmountOut(uint256 minAmountOut, uint256 amountOut);
    error SameGatewayDomain(uint32 domain);
    error UnexpectedHookData();

    constructor(address usdc_, address gatewayMinter_, address initialAdmin) {
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
        if (amountOut < receipt.minAmountOut) {
            revert InsufficientGatewayAmountOut(receipt.minAmountOut, amountOut);
        }

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
        if (context.hookData.length != 0) revert UnexpectedHookData();

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
}
