// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TurboFeeVault} from "../src/hub/TurboFeeVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFeeVaultConsumer {
    function setFeeVault(address feeVault) external;
}

/// @notice Deploy and wire TurboFeeVault for the BUFX yield engine.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   USDC
///   TURBO_FEE_TREASURY
///
/// Optional env:
///   INITIAL_ADMIN          — defaults to deployer
///   INSURANCE_ADMIN        — defaults to INITIAL_ADMIN
///   FX_PERP_CLEARINGHOUSE  — grants FEE_DEPOSITOR_ROLE and calls setFeeVault
///   FX_SPOT_EXECUTOR       — grants FEE_DEPOSITOR_ROLE and calls setFeeVault
///   TURBO_FEE_VAULT_PATH   — defaults to ../deployments/turbo-fee-vault-<chainid>.json
contract DeployTurboFeeVault is Script {
    error BootstrapAdminMustBeDeployer(address deployer, address initialAdmin);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC");
        address treasury = vm.envAddress("TURBO_FEE_TREASURY");
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);
        address insuranceAdmin = vm.envOr("INSURANCE_ADMIN", initialAdmin);
        address clearinghouse = vm.envOr("FX_PERP_CLEARINGHOUSE", address(0));
        address spotExecutor = vm.envOr("FX_SPOT_EXECUTOR", address(0));

        if (initialAdmin != deployer) revert BootstrapAdminMustBeDeployer(deployer, initialAdmin);

        string memory defaultPath =
            string.concat("../deployments/turbo-fee-vault-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("TURBO_FEE_VAULT_PATH", defaultPath);

        console2.log("============================================");
        console2.log("Deploying TurboFeeVault");
        console2.log("============================================");
        console2.log("chainId       ", block.chainid);
        console2.log("deployer      ", deployer);
        console2.log("usdc          ", usdc);
        console2.log("treasury      ", treasury);
        console2.log("initialAdmin  ", initialAdmin);
        console2.log("insuranceAdmin", insuranceAdmin);
        console2.log("clearinghouse ", clearinghouse);
        console2.log("spotExecutor  ", spotExecutor);

        vm.startBroadcast(pk);
        TurboFeeVault vault = new TurboFeeVault(IERC20(usdc), treasury);

        vault.grantRole(vault.INSURANCE_ADMIN_ROLE(), insuranceAdmin);

        _wireDepositor(vault, clearinghouse);
        _wireDepositor(vault, spotExecutor);

        vm.stopBroadcast();

        _writeManifest(path, deployer, usdc, treasury, insuranceAdmin, clearinghouse, spotExecutor, address(vault));

        console2.log("============================================");
        console2.log("TurboFeeVault", address(vault));
        console2.log("manifest     ", path);
        console2.log("============================================");
    }

    function _wireDepositor(TurboFeeVault vault, address depositor) internal {
        if (depositor == address(0)) return;
        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), depositor);
        IFeeVaultConsumer(depositor).setFeeVault(address(vault));
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address usdc,
        address treasury,
        address insuranceAdmin,
        address clearinghouse,
        address spotExecutor,
        address vault
    ) internal {
        string memory root = "turboFeeVault";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedBlockNumber", block.number);
        vm.serializeUint(root, "deployedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeAddress(root, "TurboFeeVault", vault);
        vm.serializeAddress(root, "protocolTreasury", treasury);
        vm.serializeAddress(root, "insuranceAdmin", insuranceAdmin);
        vm.serializeAddress(root, "FxPerpClearinghouse", clearinghouse);
        string memory json = vm.serializeAddress(root, "FxSpotExecutor", spotExecutor);
        vm.writeJson(json, path);
    }
}
