// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SharedFxVault} from "../src/vault/SharedFxVault.sol";

/// @notice Deploy a fresh SharedFxVault implementation (for a UUPS upgrade of the live proxy).
///         The proxy is then upgraded via `upgradeToAndCall(newImpl, migrateCalldata)` by the
///         UPGRADER_ROLE holder (KEEPER, canary). Constructor only `_disableInitializers()`.
contract DeployVaultImpl is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        SharedFxVault impl = new SharedFxVault();
        vm.stopBroadcast();
        console2.log("VAULT_IMPL_V2", address(impl));
    }
}
