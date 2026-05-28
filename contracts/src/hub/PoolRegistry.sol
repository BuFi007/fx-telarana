// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title PoolRegistry
/// @notice Maps a canonical FX pair (tokenIn → tokenOut) to a venue + pool.
///         Lets FxSpotExecutor and FxHedgeHook route through different DEX
///         backends without protocol-level redeploys.
///
///         On Arc testnet: routes point at self-LP'd pools.
///         On Arc mainnet: routes point at real Uniswap v4 pools.
///         On Avalanche mainnet: routes point at Trader Joe or Pangolin.
/// @dev    Admin-gated by multisig timelock in production (Phase 3 of the
///         decentralization spec). Read by FxSpotExecutor, FxHedgeHook, and
///         LiquidityRouter.
contract PoolRegistry is AccessControl {
    bytes32 public constant ROUTE_ADMIN_ROLE = keccak256("ROUTE_ADMIN_ROLE");

    /// @notice Supported venues for FX spot dispatch.
    enum Venue {
        SelfLP_V4, //   BUFX-deployed Uniswap v4 pool (testnet bootstrap)
        UniswapV4, //   External Uniswap v4 pool (Arc mainnet, future)
        UniswapV3, //   External Uniswap v3 pool (Avalanche, Polygon)
        TraderJoeV22, // Trader Joe v2.2 (Avalanche mainnet)
        PangolinV2, //  Pangolin V2 (Avalanche fallback)
        CrossChain //   Routes via CCTP to another chain's registry
    }

    /// @notice Route descriptor for a single tokenIn → tokenOut path.
    /// @param venue Which DEX implementation handles this swap.
    /// @param pool  Pool / pair address on this chain (zero for CrossChain).
    /// @param poolKey v4-style PoolKey hash if venue is V4-shaped.
    /// @param targetChainId Destination chain ID when venue == CrossChain.
    /// @param spreadBps Venue-specific spread/fee surcharge (bps).
    /// @param enabled If false, route is skipped during best-route selection.
    /// @param preferred If true, route wins ties against non-preferred enabled routes.
    struct Route {
        Venue venue;
        address pool;
        bytes32 poolKey;
        uint256 targetChainId;
        uint16 spreadBps;
        bool enabled;
        bool preferred;
    }

    /// @notice keccak(tokenIn, tokenOut) → ordered list of routes (best first).
    mapping(bytes32 pairKeyHash => Route[]) private _routes;

    /// @notice Venue address registry — Universal Router, SwapRouter02, LBRouter, etc.
    mapping(Venue venue => address router) public venueRouters;

    event RouteAdded(bytes32 indexed pairKey, Venue venue, address pool, uint256 chainId);
    event RouteUpdated(bytes32 indexed pairKey, uint256 idx, Venue venue, address pool, bool enabled);
    event RouteRemoved(bytes32 indexed pairKey, uint256 idx);
    event VenueRouterSet(Venue indexed venue, address router);

    error PairNotFound(bytes32 pairKey);
    error VenueRouterNotSet(Venue venue);
    error InvalidRoute();

    constructor(address admin) {
        if (admin == address(0)) revert InvalidRoute();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROUTE_ADMIN_ROLE, admin);
    }

    // ── Admin (multisig timelock in production) ─────────────────────

    /// @notice Append a route for the (tokenIn, tokenOut) pair.
    /// @dev    Order matters: bestRoute scans front-to-back. Insert preferred
    ///         routes first to bias selection.
    function addRoute(address tokenIn, address tokenOut, Route calldata route) external onlyRole(ROUTE_ADMIN_ROLE) {
        bytes32 key = pairKey(tokenIn, tokenOut);
        _routes[key].push(route);
        emit RouteAdded(key, route.venue, route.pool, route.targetChainId);
    }

    /// @notice Replace the route at `idx` for the (tokenIn, tokenOut) pair.
    function updateRoute(address tokenIn, address tokenOut, uint256 idx, Route calldata route)
        external
        onlyRole(ROUTE_ADMIN_ROLE)
    {
        bytes32 key = pairKey(tokenIn, tokenOut);
        if (idx >= _routes[key].length) revert InvalidRoute();
        _routes[key][idx] = route;
        emit RouteUpdated(key, idx, route.venue, route.pool, route.enabled);
    }

    /// @notice Register the canonical router address for a venue.
    /// @dev    Consumed by LiquidityRouter when dispatching swaps.
    function setVenueRouter(Venue venue, address router) external onlyRole(ROUTE_ADMIN_ROLE) {
        venueRouters[venue] = router;
        emit VenueRouterSet(venue, router);
    }

    // ── Read paths ─────────────────────────────────────────────────

    /// @notice Canonical ordered pair key. Direction-sensitive: pairKey(A,B) != pairKey(B,A).
    function pairKey(address tokenIn, address tokenOut) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    /// @notice Returns the best enabled route for a pair.
    /// @dev    First pass picks any enabled+preferred route; second pass takes
    ///         the first enabled route. Reverts if none enabled.
    function bestRoute(address tokenIn, address tokenOut) external view returns (Route memory) {
        bytes32 key = pairKey(tokenIn, tokenOut);
        Route[] storage list = _routes[key];
        uint256 len = list.length;
        if (len == 0) revert PairNotFound(key);

        // First pass: preferred + enabled
        for (uint256 i = 0; i < len; i++) {
            if (list[i].enabled && list[i].preferred) return list[i];
        }
        // Second pass: first enabled
        for (uint256 i = 0; i < len; i++) {
            if (list[i].enabled) return list[i];
        }
        revert PairNotFound(key);
    }

    /// @notice Returns the full route list for a pair (enabled + disabled).
    function allRoutes(address tokenIn, address tokenOut) external view returns (Route[] memory) {
        return _routes[pairKey(tokenIn, tokenOut)];
    }

    /// @notice Returns the number of routes registered for a pair.
    function routeCount(address tokenIn, address tokenOut) external view returns (uint256) {
        return _routes[pairKey(tokenIn, tokenOut)].length;
    }

    /// @notice Returns the route at `idx` for a pair. Reverts on out-of-range.
    function routeAt(address tokenIn, address tokenOut, uint256 idx) external view returns (Route memory) {
        Route[] storage list = _routes[pairKey(tokenIn, tokenOut)];
        if (idx >= list.length) revert InvalidRoute();
        return list[idx];
    }
}
