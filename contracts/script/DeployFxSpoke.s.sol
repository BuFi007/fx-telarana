// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxSpoke} from "../src/spoke/FxSpoke.sol";

/// @notice Phase 0 Spoke deployment. Run once per spoke chain (Ethereum, Base).
///
/// Required env vars (per chain):
///   DEPLOYER_PRIVATE_KEY
///   SPOKE_USDC                     — USDC address on this spoke
///   SPOKE_CCTP_TOKEN_MESSENGER     — TokenMessengerV2 on this spoke
///   ARC_HUB_RECEIVER               — FxHubMessageReceiver address on Arc
///   ARC_DOMAIN                     — 26
contract DeployFxSpoke is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address usdc       = vm.envAddress("SPOKE_USDC");
        address tokenMsgr  = vm.envAddress("SPOKE_CCTP_TOKEN_MESSENGER");
        address hubReceiver = vm.envAddress("ARC_HUB_RECEIVER");
        uint32  arcDomain  = uint32(vm.envUint("ARC_DOMAIN"));

        vm.startBroadcast(pk);
        FxSpoke spoke = new FxSpoke(tokenMsgr, usdc, hubReceiver, arcDomain);
        vm.stopBroadcast();

        console2.log("FxSpoke", address(spoke));
    }
}
