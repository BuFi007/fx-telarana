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
///   POOL_MANAGER    — Uniswap v4 PoolManager on this chain (PR-H8 / Wave L2)
///
/// Optional env:
///   INITIAL_ADMIN   — defaults to the deployer
///
/// IMPORTANT (PR-H8):
///   This deploy path produces a hook address with arbitrary low-order bits.
///   For real v4 PoolManager attachment the address MUST encode BEFORE_SWAP_FLAG
///   (1 << 7) and BEFORE_SWAP_RETURNS_DELTA_FLAG (1 << 3) in its low 14 bits.
///   Use `script/MineHookSalt.s.sol` to mine a CREATE2 salt before broadcasting
///   this script via `forge script --create2-salt <mined-salt>`. The naive
///   `new TelaranaGatewayHubHook(...)` here is retained for legacy executor-only
///   deployments where the hook is NOT attached to a Uniswap v4 pool.
///
/// Post-deploy wiring (separate broadcast — see scripts/configure-tgh.ts):
///   setGatewayRoute(routeId, ...) for each direction TGH should accept
///   setGatewayContextProofMode(routeId, SIGNED_INTENT_OR_HYPERLANE) for receipt parity
///   grantRole(EXECUTOR_ROLE, keeperEOA)
///   setPoolGatewayRoute(poolId, routeId) for each v4 pool that should pull
///   Gateway-routed intra-hook liquidity inside beforeSwap (PR-H8)
contract DeployTelaranaGatewayHubHook is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address gatewayMinter = vm.envAddress("GATEWAY_MINTER");
        address usdc = vm.envAddress("USDC");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);

        console2.log("============================================");
        console2.log("Deploying TelaranaGatewayHubHook");
        console2.log("============================================");
        console2.log("deployer       ", deployer);
        console2.log("usdc           ", usdc);
        console2.log("gatewayMinter  ", gatewayMinter);
        console2.log("poolManager    ", poolManager);
        console2.log("initialAdmin   ", initialAdmin);

        vm.startBroadcast(pk);
        TelaranaGatewayHubHook hook = new TelaranaGatewayHubHook(usdc, gatewayMinter, poolManager, initialAdmin);
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
        console2.log("  6. setPoolGatewayRoute(poolId, routeId) for each Uniswap v4 pool that");
        console2.log("     should pull Gateway-routed liquidity in beforeSwap (PR-H8)");
    }
}
