// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title ITelaranaSpotFxRouter
/// @notice Preparation interface for future Telarana spot FX request intake.
/// @dev This is intentionally interface-only. It defines request/event surfaces
///      for future whitelisted requesters and Uniswap v4 spot execution without
///      implementing matching, hooks, settlement, or request storage.
interface ITelaranaSpotFxRouter {
    enum RequesterKind {
        INTERNAL,
        BUFX,
        RFQ_PASILLO,
        PARTNER
    }

    enum ExecutionStatus {
        REQUESTED,
        QUOTED,
        ACCEPTED,
        EXECUTED,
        CANCELLED,
        EXPIRED,
        FAILED
    }

    enum RouteKind {
        UNISWAP_V4_SPOT,
        RFQ_PASILLO,
        INTERNAL_TEST
    }

    struct SpotFxRequest {
        address requester;
        RequesterKind requesterKind;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes32 routeId;
        address recipient;
        uint256 deadline;
        bytes32 metadataRef;
    }

    struct RouteConfig {
        RouteKind routeKind;
        address tokenIn;
        address tokenOut;
        bytes32 poolId;
        address hook;
        address whitelistedCaller;
        bool enabled;
        bytes32 metadataRef;
    }

    struct PoolConfig {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        address hook;
        bytes32 metadataRef;
    }

    event SpotFxRequestCreated(
        bytes32 indexed requestId,
        address indexed requester,
        RequesterKind requesterKind,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes32 routeId,
        address recipient,
        uint256 deadline,
        bytes32 metadataRef
    );

    event SpotFxRequestAccepted(bytes32 indexed requestId, address indexed accepter, uint256 amountOut);

    event SpotFxRequestExecuted(bytes32 indexed requestId, address indexed executor, uint256 amountOut);

    event SpotFxRequestCancelled(bytes32 indexed requestId, address indexed requester);

    event WhitelistedRequesterUpdated(address indexed requester, RequesterKind requesterKind, bool allowed);

    event RouteConfigured(
        bytes32 indexed routeId,
        RouteKind routeKind,
        address tokenIn,
        address tokenOut,
        bytes32 poolId,
        address hook,
        address whitelistedCaller,
        bool enabled,
        bytes32 metadataRef
    );

    event PoolConfigured(
        bytes32 indexed poolId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        address hook,
        bytes32 metadataRef
    );

    function whitelistedRequester(address requester) external view returns (bool allowed, RequesterKind requesterKind);

    function createSpotFxRequest(SpotFxRequest calldata request) external returns (bytes32 requestId);

    function cancelSpotFxRequest(bytes32 requestId) external;
}
