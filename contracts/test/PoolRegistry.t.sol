// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PoolRegistry} from "../src/hub/PoolRegistry.sol";

contract PoolRegistryTest is Test {
    PoolRegistry internal registry;

    address internal admin = address(0xA11CE);
    address internal outsider = address(0xBADBABE);
    address internal tokenA = address(0xAAA1);
    address internal tokenB = address(0xBBB2);
    address internal poolFallback = address(0xF00D);
    address internal poolPreferred = address(0xCAFE);

    function setUp() public {
        registry = new PoolRegistry(admin);
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function _route(PoolRegistry.Venue venue, address pool, bool enabled, bool preferred)
        internal
        pure
        returns (PoolRegistry.Route memory)
    {
        return PoolRegistry.Route({
            venue: venue,
            pool: pool,
            poolKey: bytes32(uint256(uint160(pool))),
            targetChainId: 0,
            spreadBps: 5,
            enabled: enabled,
            preferred: preferred
        });
    }

    // ── Tests ────────────────────────────────────────────────────────

    function test_addRouteAndRetrieve() public {
        PoolRegistry.Route memory r = _route(PoolRegistry.Venue.UniswapV4, poolFallback, true, false);

        vm.prank(admin);
        registry.addRoute(tokenA, tokenB, r);

        PoolRegistry.Route memory got = registry.bestRoute(tokenA, tokenB);
        assertEq(uint256(got.venue), uint256(PoolRegistry.Venue.UniswapV4));
        assertEq(got.pool, poolFallback);
        assertTrue(got.enabled);
        assertEq(registry.routeCount(tokenA, tokenB), 1);

        PoolRegistry.Route[] memory list = registry.allRoutes(tokenA, tokenB);
        assertEq(list.length, 1);
        assertEq(list[0].pool, poolFallback);
    }

    function test_preferredRouteWinsWhenMultipleEnabled() public {
        // Non-preferred goes in first (would otherwise win on first-enabled scan).
        PoolRegistry.Route memory fallbackRoute = _route(PoolRegistry.Venue.UniswapV3, poolFallback, true, false);
        PoolRegistry.Route memory preferredRoute = _route(PoolRegistry.Venue.UniswapV4, poolPreferred, true, true);

        vm.startPrank(admin);
        registry.addRoute(tokenA, tokenB, fallbackRoute);
        registry.addRoute(tokenA, tokenB, preferredRoute);
        vm.stopPrank();

        PoolRegistry.Route memory got = registry.bestRoute(tokenA, tokenB);
        assertEq(got.pool, poolPreferred, "preferred route must win");
        assertEq(uint256(got.venue), uint256(PoolRegistry.Venue.UniswapV4));
    }

    function test_disabledRouteFallsThrough() public {
        // Disabled preferred should be skipped; second enabled non-preferred wins.
        PoolRegistry.Route memory disabledPreferred = _route(PoolRegistry.Venue.UniswapV4, poolPreferred, false, true);
        PoolRegistry.Route memory enabledFallback = _route(PoolRegistry.Venue.UniswapV3, poolFallback, true, false);

        vm.startPrank(admin);
        registry.addRoute(tokenA, tokenB, disabledPreferred);
        registry.addRoute(tokenA, tokenB, enabledFallback);
        vm.stopPrank();

        PoolRegistry.Route memory got = registry.bestRoute(tokenA, tokenB);
        assertEq(got.pool, poolFallback, "disabled preferred route must be skipped");
        assertEq(uint256(got.venue), uint256(PoolRegistry.Venue.UniswapV3));
    }

    function test_revertsOnPairNotFound() public {
        bytes32 key = registry.pairKey(tokenA, tokenB);
        vm.expectRevert(abi.encodeWithSelector(PoolRegistry.PairNotFound.selector, key));
        registry.bestRoute(tokenA, tokenB);
    }

    function test_revertsWhenAllRoutesDisabled() public {
        PoolRegistry.Route memory r = _route(PoolRegistry.Venue.UniswapV4, poolFallback, false, false);
        vm.prank(admin);
        registry.addRoute(tokenA, tokenB, r);

        bytes32 key = registry.pairKey(tokenA, tokenB);
        vm.expectRevert(abi.encodeWithSelector(PoolRegistry.PairNotFound.selector, key));
        registry.bestRoute(tokenA, tokenB);
    }

    function test_onlyAdminCanAddRoute() public {
        PoolRegistry.Route memory r = _route(PoolRegistry.Venue.UniswapV4, poolFallback, true, false);
        bytes32 role = registry.ROUTE_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        registry.addRoute(tokenA, tokenB, r);
    }

    function test_onlyAdminCanUpdateRoute() public {
        PoolRegistry.Route memory r = _route(PoolRegistry.Venue.UniswapV4, poolFallback, true, false);
        vm.prank(admin);
        registry.addRoute(tokenA, tokenB, r);

        PoolRegistry.Route memory updated = _route(PoolRegistry.Venue.UniswapV3, poolPreferred, true, true);
        bytes32 role = registry.ROUTE_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        registry.updateRoute(tokenA, tokenB, 0, updated);
    }

    function test_updateRouteReplacesEntry() public {
        PoolRegistry.Route memory r = _route(PoolRegistry.Venue.UniswapV4, poolFallback, true, false);
        vm.prank(admin);
        registry.addRoute(tokenA, tokenB, r);

        PoolRegistry.Route memory replacement = _route(PoolRegistry.Venue.UniswapV3, poolPreferred, true, true);
        vm.prank(admin);
        registry.updateRoute(tokenA, tokenB, 0, replacement);

        PoolRegistry.Route memory got = registry.bestRoute(tokenA, tokenB);
        assertEq(got.pool, poolPreferred);
        assertEq(uint256(got.venue), uint256(PoolRegistry.Venue.UniswapV3));
        assertTrue(got.preferred);
    }

    function test_updateRouteRevertsOnOutOfRange() public {
        PoolRegistry.Route memory r = _route(PoolRegistry.Venue.UniswapV4, poolFallback, true, false);
        vm.prank(admin);
        vm.expectRevert(PoolRegistry.InvalidRoute.selector);
        registry.updateRoute(tokenA, tokenB, 0, r); // empty list, idx 0 out of range
    }

    function test_setVenueRouter() public {
        address router = address(0xF00F);
        vm.prank(admin);
        registry.setVenueRouter(PoolRegistry.Venue.UniswapV3, router);
        assertEq(registry.venueRouters(PoolRegistry.Venue.UniswapV3), router);
    }

    function test_onlyAdminCanSetVenueRouter() public {
        bytes32 role = registry.ROUTE_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        registry.setVenueRouter(PoolRegistry.Venue.UniswapV3, address(0x1234));
    }

    function test_pairKeyIsDirectional() public view {
        bytes32 ab = registry.pairKey(tokenA, tokenB);
        bytes32 ba = registry.pairKey(tokenB, tokenA);
        assertTrue(ab != ba, "pair key must be direction-sensitive");
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(PoolRegistry.InvalidRoute.selector);
        new PoolRegistry(address(0));
    }
}
