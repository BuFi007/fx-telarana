// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title ITelaranaGatewayHubHook
/// @notice Preparation interface for Circle Gateway hub-to-hub USDC liquidity.
/// @dev
/// Data flow:
///   Fuji/Arc hub operator EOA -> Gateway BurnIntent signature
///   Circle Gateway API       -> attestation + API signature
///   destination hub caller   -> TelaranaGatewayHubHook.receiveGatewayMint(...)
///   hook                     -> GatewayMinter.gatewayMint(...)
///   hook                     -> optional Telarana spot FX request / route event
interface ITelaranaGatewayHubHook {
    enum GatewaySignerMode {
        EOA,
        ERC1271_CONTRACT_FUTURE
    }

    enum GatewayHubAction {
        MINT_TO_HUB,
        MINT_AND_REQUEST_SPOT_FX
    }

    struct GatewayHubRoute {
        uint32 sourceDomain;
        uint32 destinationDomain;
        address sourceUsdc;
        address destinationUsdc;
        address sourceGatewayWallet;
        address destinationGatewayMinter;
        address destinationHub;
        address whitelistedCaller;
        GatewaySignerMode signerMode;
        bool enabled;
        bytes32 metadataRef;
    }

    struct GatewayMintContext {
        bytes32 routeId;
        bytes32 requestId;
        GatewayHubAction action;
        address sourceDepositor;
        address sourceSigner;
        address recipient;
        uint256 amount;
        uint256 minAmountOut;
        bytes32 spotRouteId;
        bytes32 metadataRef;
        bytes hookData;
    }

    event GatewayHubRouteConfigured(
        bytes32 indexed routeId,
        uint32 indexed sourceDomain,
        uint32 indexed destinationDomain,
        address sourceUsdc,
        address destinationUsdc,
        address sourceGatewayWallet,
        address destinationGatewayMinter,
        GatewaySignerMode signerMode,
        bool enabled,
        bytes32 metadataRef
    );

    event GatewayHubTransferRequested(
        bytes32 indexed requestId,
        bytes32 indexed routeId,
        address indexed sourceSigner,
        address sourceDepositor,
        address destinationRecipient,
        uint256 amount,
        uint256 maxFee,
        uint256 deadline,
        bytes32 metadataRef
    );

    event GatewayHubBurnIntentSigned(
        bytes32 indexed requestId,
        address indexed sourceSigner,
        uint32 sourceDomain,
        uint32 destinationDomain,
        uint256 amount,
        bytes32 salt
    );

    event GatewayHubMintAttested(
        bytes32 indexed requestId, bytes32 indexed routeId, address destinationMinter, bytes32 attestationHash
    );

    event GatewayHubLiquidityReceived(
        bytes32 indexed requestId,
        bytes32 indexed routeId,
        address indexed recipient,
        address destinationUsdc,
        uint256 amount
    );

    event GatewayAtomicFxSwapRequested(
        bytes32 indexed requestId,
        bytes32 indexed routeId,
        bytes32 indexed spotRouteId,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32 metadataRef
    );

    event GatewayAtomicFxSwapSettled(
        bytes32 indexed requestId,
        bytes32 indexed spotRouteId,
        address indexed recipient,
        address tokenOut,
        uint256 amountOut
    );

    event GatewaySignerModeUpdated(bytes32 indexed routeId, GatewaySignerMode signerMode, bool allowed);

    function gatewayRoute(bytes32 routeId) external view returns (GatewayHubRoute memory route);

    function receiveGatewayMint(
        bytes calldata attestationPayload,
        bytes calldata signature,
        GatewayMintContext calldata context
    ) external returns (uint256 amountReceived);
}

