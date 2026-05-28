// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolRegistry} from "../src/hub/PoolRegistry.sol";
import {LiquidityRouter} from "../src/hub/LiquidityRouter.sol";

/// @notice Deploys the PoolRegistry + LiquidityRouter pair.
///
///         Phase 1 of the spot-routing migration (see
///         docs/architecture/pool-registry-spec.md). Subsequent scripts will
///         wire venue routers (Universal Router, SwapRouter02, LBRouter) and
///         seed initial routes per chain.
///
/// Required env:
///   POOL_REGISTRY_ADMIN — address granted DEFAULT_ADMIN_ROLE + ROUTE_ADMIN_ROLE.
///
/// Usage:
///   forge script script/DeployPoolRegistryStack.s.sol --rpc-url $ARC_RPC_URL --broadcast
///
/// @dev This script does NOT call `vm.startBroadcast` automatically — drive it
///      via the standard `--broadcast` flag so the same script can be used for
///      dry-runs and live deploys.
contract DeployPoolRegistryStack is Script {
    function run() external returns (PoolRegistry registry, LiquidityRouter router) {
        address admin = vm.envAddress("POOL_REGISTRY_ADMIN");

        vm.startBroadcast();

        registry = new PoolRegistry(admin);
        router = new LiquidityRouter(registry);

        vm.stopBroadcast();

        console2.log("PoolRegistry deployed at:", address(registry));
        console2.log("LiquidityRouter deployed at:", address(router));
        console2.log("Admin:", admin);
        console2.log("Chain ID:", block.chainid);
    }
}
