// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

interface ITurboFeeVaultAdmin {
    function USDC() external view returns (address);
    function FEE_DEPOSITOR_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function protocolTreasury() external view returns (address);
}

interface IFeeVaultConsumer {
    function setFeeVault(address feeVault) external;
}

/// @notice Wires an existing TurboFeeVault into upgraded trading consumers.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   TURBO_FEE_VAULT
///
/// Optional env:
///   FX_PERP_CLEARINGHOUSE  — grants FEE_DEPOSITOR_ROLE and calls setFeeVault
///   FX_SPOT_EXECUTOR       — grants FEE_DEPOSITOR_ROLE and calls setFeeVault
///   TURBO_FEE_VAULT_PATH   — defaults to ../deployments/turbo-fee-vault-<chainid>.json
contract WireTurboFeeVault is Script {
    error ZeroVault();
    error NoConsumers();

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vaultAddress = vm.envAddress("TURBO_FEE_VAULT");
        address clearinghouse = vm.envOr("FX_PERP_CLEARINGHOUSE", address(0));
        address spotExecutor = vm.envOr("FX_SPOT_EXECUTOR", address(0));

        if (vaultAddress == address(0)) revert ZeroVault();
        if (clearinghouse == address(0) && spotExecutor == address(0)) revert NoConsumers();

        ITurboFeeVaultAdmin vault = ITurboFeeVaultAdmin(vaultAddress);
        string memory defaultPath =
            string.concat("../deployments/turbo-fee-vault-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("TURBO_FEE_VAULT_PATH", defaultPath);

        console2.log("============================================");
        console2.log("Wiring TurboFeeVault");
        console2.log("============================================");
        console2.log("chainId       ", block.chainid);
        console2.log("deployer      ", deployer);
        console2.log("vault         ", vaultAddress);
        console2.log("clearinghouse ", clearinghouse);
        console2.log("spotExecutor  ", spotExecutor);

        vm.startBroadcast(pk);
        _wireDepositor(vault, vaultAddress, clearinghouse);
        _wireDepositor(vault, vaultAddress, spotExecutor);
        vm.stopBroadcast();

        _writeManifest(path, deployer, vault, vaultAddress, clearinghouse, spotExecutor);

        console2.log("manifest", path);
    }

    function _wireDepositor(ITurboFeeVaultAdmin vault, address vaultAddress, address depositor) internal {
        if (depositor == address(0)) return;
        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), depositor);
        IFeeVaultConsumer(depositor).setFeeVault(vaultAddress);
    }

    function _writeManifest(
        string memory path,
        address deployer,
        ITurboFeeVaultAdmin vault,
        address vaultAddress,
        address clearinghouse,
        address spotExecutor
    ) internal {
        string memory root = "turboFeeVault";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "wiredBlockNumber", block.number);
        vm.serializeUint(root, "wiredBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "TurboFeeVault", vaultAddress);
        vm.serializeAddress(root, "USDC", vault.USDC());
        vm.serializeAddress(root, "protocolTreasury", vault.protocolTreasury());
        vm.serializeAddress(root, "FxPerpClearinghouse", clearinghouse);
        string memory json = vm.serializeAddress(root, "FxSpotExecutor", spotExecutor);
        vm.writeJson(json, path);
    }
}
