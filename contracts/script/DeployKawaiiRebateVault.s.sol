// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {KawaiiRebateVault} from "../src/hub/KawaiiRebateVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploy KawaiiRebateVault (TurboFeeVault P3 vested rebates).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY   — deployer + DEFAULT_ADMIN (the keeper 0xcA02)
///   USDC                   — settlement token (Arc: 0x3600000000000000000000000000000000000000)
///
/// Optional env:
///   VEST_DURATION          — linear vest window seconds (default 604800 = 7d)
///   REBATE_ALLOCATOR       — keeper that allocates rebates (default deployer)
///   REBATE_FUNDER          — funds the pool (default deployer)
///   REBATE_PAUSER          — guardian circuit breaker (default deployer)
///   KAWAII_REBATE_VAULT_PATH — default ../deployments/kawaii-rebate-vault-<chainid>.json
contract DeployKawaiiRebateVault is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC");
        uint256 vest = vm.envOr("VEST_DURATION", uint256(7 days));
        address allocator = vm.envOr("REBATE_ALLOCATOR", deployer);
        address funder = vm.envOr("REBATE_FUNDER", deployer);
        address pauser = vm.envOr("REBATE_PAUSER", deployer);

        string memory defaultPath =
            string.concat("../deployments/kawaii-rebate-vault-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("KAWAII_REBATE_VAULT_PATH", defaultPath);

        console2.log("============================================");
        console2.log("Deploying KawaiiRebateVault");
        console2.log("chainId   ", block.chainid);
        console2.log("deployer  ", deployer);
        console2.log("usdc      ", usdc);
        console2.log("vestSecs  ", vest);
        console2.log("allocator ", allocator);
        console2.log("funder    ", funder);
        console2.log("pauser    ", pauser);

        vm.startBroadcast(pk);
        KawaiiRebateVault vault = new KawaiiRebateVault(IERC20(usdc), vest, deployer);
        vault.grantRole(vault.REBATE_ALLOCATOR_ROLE(), allocator);
        vault.grantRole(vault.REBATE_FUNDER_ROLE(), funder);
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        vm.stopBroadcast();

        string memory root = "kawaiiRebateVault";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedBlockNumber", block.number);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeAddress(root, "KawaiiRebateVault", address(vault));
        vm.serializeUint(root, "vestDuration", vest);
        vm.serializeAddress(root, "allocator", allocator);
        vm.serializeAddress(root, "funder", funder);
        string memory json = vm.serializeAddress(root, "pauser", pauser);
        vm.writeJson(json, path);

        console2.log("KawaiiRebateVault", address(vault));
        console2.log("manifest", path);
        console2.log("============================================");
    }
}
