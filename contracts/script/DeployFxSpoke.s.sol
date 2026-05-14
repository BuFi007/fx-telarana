// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxSpoke} from "../src/spoke/FxSpoke.sol";

/// @notice Per-spoke-chain deploy of `FxSpoke`. Detects chainId at runtime and applies
///         built-in defaults for CCTP V2 + USDC + the live Base-Sepolia hub.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///
/// Optional env (override the built-in defaults for the detected chain):
///   SPOKE_USDC                     — USDC on this spoke
///   SPOKE_CCTP_TOKEN_MESSENGER     — CCTP V2 TokenMessenger
///   HUB_RECEIVER                   — FxHubMessageReceiver on the hub chain
///   HUB_DOMAIN                     — CCTP V2 domain id of the destination hub
///
/// Supported chains today:
///   * Unichain Sepolia  (1301)
///   * Avalanche Fuji    (43113)
///   * Base Sepolia      (84532) — only useful for self-loop testing
contract DeployFxSpoke is Script {
    // CCTP V2 testnet uses the same deterministic addresses across chains.
    address constant CCTP_V2_TOKEN_MESSENGER     = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    // address constant CCTP_V2_MESSAGE_TRANSMITTER = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

    // Live Base Sepolia hub (v3, deployed 2026-05-14).
    address constant DEFAULT_HUB_RECEIVER = 0x758c17BfA85D1b26A81423B524397b8b2D271818;
    uint32  constant DEFAULT_HUB_DOMAIN   = 6; // Base Sepolia CCTP V2 domain

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 chainId = block.chainid;

        (address defaultUsdc, string memory chainName) = _defaults(chainId);

        address usdc        = vm.envOr("SPOKE_USDC", defaultUsdc);
        address tokenMsgr   = vm.envOr("SPOKE_CCTP_TOKEN_MESSENGER", CCTP_V2_TOKEN_MESSENGER);
        address hubReceiver = vm.envOr("HUB_RECEIVER", DEFAULT_HUB_RECEIVER);
        uint32  hubDomain   = uint32(vm.envOr("HUB_DOMAIN", uint256(DEFAULT_HUB_DOMAIN)));

        console2.log("chain   ", chainName);
        console2.log("chainId ", chainId);
        console2.log("usdc    ", usdc);
        console2.log("cctp tm ", tokenMsgr);
        console2.log("hub recv", hubReceiver);
        console2.log("hub dom ", uint256(hubDomain));

        vm.startBroadcast(pk);
        FxSpoke spoke = new FxSpoke(tokenMsgr, usdc, hubReceiver, hubDomain);
        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("FxSpoke deployed on", chainName);
        console2.log("============================================");
        console2.log("FxSpoke", address(spoke));
    }

    function _defaults(uint256 chainId)
        internal
        pure
        returns (address usdc, string memory name)
    {
        if (chainId == 11155111) {
            // Ethereum Sepolia, CCTP V2 domain 0
            return (0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, "ethereum-sepolia");
        }
        if (chainId == 43113) {
            // Avalanche Fuji, CCTP V2 domain 1
            return (0x5425890298aed601595a70AB815c96711a31Bc65, "avalanche-fuji");
        }
        if (chainId == 11155420) {
            // OP Sepolia, CCTP V2 domain 2
            return (0x5fd84259d66Cd46123540766Be93DFE6D43130D7, "op-sepolia");
        }
        if (chainId == 421614) {
            // Arbitrum Sepolia, CCTP V2 domain 3
            return (0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d, "arbitrum-sepolia");
        }
        if (chainId == 84532) {
            return (0x036CbD53842c5426634e7929541eC2318f3dCF7e, "base-sepolia-selfloop");
        }
        if (chainId == 80002) {
            // Polygon Amoy, CCTP V2 domain 7
            return (0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582, "polygon-amoy");
        }
        if (chainId == 1301) {
            // Unichain Sepolia, CCTP V2 domain 10
            return (0x31d0220469e10c4E71834a79b1f276d740d3768F, "unichain-sepolia");
        }
        if (chainId == 59141) {
            // Linea Sepolia, CCTP V2 domain 11
            return (0xFEce4462D57bD51A6A552365A011b95f0E16d9B7, "linea-sepolia");
        }
        if (chainId == 4801) {
            // World Chain Sepolia, CCTP V2 domain 14
            return (0x66145f38cBAC35Ca6F1Dfb4914dF98F1614aeA88, "worldchain-sepolia");
        }
        revert("unsupported chainId: pass SPOKE_USDC + SPOKE_CCTP_TOKEN_MESSENGER explicitly");
    }
}
