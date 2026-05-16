// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxGatewayHook} from "../src/hub/FxGatewayHook.sol";

/// @notice Per-chain deploy of `FxGatewayHook`. Same code on every hub chain; the per-chain
/// Circle Gateway addresses + the local hub address come from env.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   GATEWAY_WALLET             — Circle GatewayWallet on this chain
///   GATEWAY_MINTER             — Circle GatewayMinter on this chain
///   HUB                        — local FxHubMessageReceiver address
///   USDC                       — USDC token address on this chain
///   GATEWAY_LOCAL_DOMAIN       — Circle Gateway domain ID for this chain (NOT CCTP V2 domain)
///   GATEWAY_AUTHORITY          — initial BurnIntent-signing authority (EOA now; HUB itself post-1271)
contract DeployFxGatewayHook is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address gatewayWallet = vm.envAddress("GATEWAY_WALLET");
        address gatewayMinter = vm.envAddress("GATEWAY_MINTER");
        address hub           = vm.envAddress("HUB");
        address usdc          = vm.envAddress("USDC");
        uint32  localDomain   = uint32(vm.envUint("GATEWAY_LOCAL_DOMAIN"));
        address authority     = vm.envAddress("GATEWAY_AUTHORITY");

        console2.log("============================================");
        console2.log("Deploying FxGatewayHook");
        console2.log("============================================");
        console2.log("deployer       ", deployer);
        console2.log("usdc           ", usdc);
        console2.log("gatewayWallet  ", gatewayWallet);
        console2.log("gatewayMinter  ", gatewayMinter);
        console2.log("hub            ", hub);
        console2.log("localDomain    ", uint256(localDomain));
        console2.log("authority      ", authority);

        vm.startBroadcast(pk);
        FxGatewayHook hook = new FxGatewayHook(
            usdc, gatewayWallet, gatewayMinter, hub, localDomain, authority
        );
        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("FxGatewayHook", address(hook));
        console2.log("============================================");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Save the address into deployments/<chain>.json");
        console2.log("  2. Have the hub approve this hook to spend USDC for `lockForRemote`");
        console2.log("  3. Wire FxSwapHook.beforeSwap / afterSwap to call lockForRemote / mintFromRemote");
        console2.log("  4. Off-chain: implement the BurnIntent signer service");
        console2.log("     (EOA now; migrate to hub-contract via EIP-1271 post Circle's mid-July ETA)");
    }
}
