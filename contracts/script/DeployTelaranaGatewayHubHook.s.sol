// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TelaranaGatewayHubHook} from "../src/hub/TelaranaGatewayHubHook.sol";

/// @notice Per-chain deploy of `TelaranaGatewayHubHook`. This is the
///         spot-FX-aware destination wrapper for Circle Gateway mints; it
///         coexists with `FxGatewayHook` (the simpler mint-to-hub-only path).
///         Use the simpler hook for plain cross-hub USDC liquidity moves and
///         this hook when the BUFX request encodes a MINT_AND_REQUEST_SPOT_FX
///         action — TGH emits `GatewayAtomicFxSwapRequested` for the
///         downstream execution layer.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   GATEWAY_MINTER  — Circle GatewayMinter on this chain
///   USDC            — USDC token address on this chain
///
/// Optional env:
///   INITIAL_ADMIN   — defaults to the deployer
///
/// Post-deploy wiring (separate broadcast — see scripts/configure-tgh.ts):
///   setGatewayRoute(routeId, ...) for each direction TGH should accept
///   setGatewayContextProofMode(routeId, SIGNED_INTENT_OR_HYPERLANE) for receipt parity
///   grantRole(EXECUTOR_ROLE, keeperEOA)
contract DeployTelaranaGatewayHubHook is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address gatewayMinter = vm.envAddress("GATEWAY_MINTER");
        address usdc = vm.envAddress("USDC");
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);

        console2.log("============================================");
        console2.log("Deploying TelaranaGatewayHubHook");
        console2.log("============================================");
        console2.log("deployer       ", deployer);
        console2.log("usdc           ", usdc);
        console2.log("gatewayMinter  ", gatewayMinter);
        console2.log("initialAdmin   ", initialAdmin);

        vm.startBroadcast(pk);
        TelaranaGatewayHubHook hook = new TelaranaGatewayHubHook(usdc, gatewayMinter, initialAdmin);
        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("TelaranaGatewayHubHook", address(hook));
        console2.log("============================================");
        console2.log("");
        console2.log("Next steps (do NOT skip):");
        console2.log("  1. Save the address into deployments/<chain>.json + hub-config-<chain>.json");
        console2.log("  2. Configure GatewayHubRoute via setGatewayRoute for each route this hook accepts");
        console2.log("  3. Configure GatewayContextProofMode for every spot-FX route");
        console2.log("  4. Grant EXECUTOR_ROLE to the keeper EOA that will call receiveGatewayMint");
        console2.log("  5. Update the off-chain BurnIntent signer to target this hook as");
        console2.log("     destinationRecipient + destinationCaller for spot-FX BurnIntents");
    }
}
