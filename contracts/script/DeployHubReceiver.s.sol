// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";

/// @notice One-shot deploy of `FxHubMessageReceiver` against an existing
///         FxMarketRegistry deployment. Use when the rest of the hub is
///         already live and you only need to add the CCTP V2 inbound endpoint.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   HUB_REGISTRY            — live FxMarketRegistry
///   HUB_USDC                — USDC on this chain
///   HUB_CCTP_MT             — CCTP V2 MessageTransmitter on this chain
contract DeployHubReceiver is Script {
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address registry  = vm.envAddress("HUB_REGISTRY");
        address usdc      = vm.envAddress("HUB_USDC");
        address cctpMt    = vm.envAddress("HUB_CCTP_MT");

        console2.log("registry", registry);
        console2.log("usdc    ", usdc);
        console2.log("cctp mt ", cctpMt);

        vm.startBroadcast(pk);
        FxHubMessageReceiver hubReceiver = new FxHubMessageReceiver(cctpMt, usdc, registry);
        vm.stopBroadcast();

        console2.log("FxHubMessageReceiver", address(hubReceiver));
    }
}
