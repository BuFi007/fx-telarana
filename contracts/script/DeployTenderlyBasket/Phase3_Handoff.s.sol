// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {BasketDeployBase} from "./BasketDeployBase.sol";

import {FxOracle} from "../../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../../src/hub/FxMarketRegistry.sol";
import {FxLiquidator} from "../../src/hub/FxLiquidator.sol";
import {FxTimelock} from "../../src/governance/FxTimelock.sol";

/// @notice Phase 3: deploys FxTimelock and hands DEFAULT_ADMIN_ROLE off from
///         deployer → timelock atomically on FxOracle, FxMarketRegistry,
///         and FxLiquidator. Asserts the deployer no longer holds admin
///         after the role transfers. Emits `phase3-handoff.json`.
///
/// Tenderly Pro TUs budget: 1 timelock deploy + 6 role txs = 7 txs. Fits.
contract Phase3_Handoff is BasketDeployBase {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        require(
            block.chainid == 43113 || block.chainid == 5042002,
            "Phase3: testnet-only (Fuji 43113 or Arc 5042002)"
        );

        address oracleAddr = _readManifestAddress("FxOracle");
        address registryAddr = _readManifestAddress("FxMarketRegistry");
        address liquidatorAddr = _readManifestAddress("FxLiquidator");

        FxOracle oracle = FxOracle(oracleAddr);
        FxMarketRegistry registry = FxMarketRegistry(registryAddr);
        FxLiquidator liquidator = FxLiquidator(liquidatorAddr);

        // Pre-check: deployer must currently hold admin on all three.
        require(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), deployer), "Phase3: deployer is not oracle admin");
        require(
            registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer),
            "Phase3: deployer is not registry admin"
        );
        require(
            liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer),
            "Phase3: deployer is not liq admin"
        );

        vm.startBroadcast(pk);

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        FxTimelock timelock = new FxTimelock(24 hours, proposers, executors, address(0));

        oracle.grantRole(oracle.DEFAULT_ADMIN_ROLE(), address(timelock));
        oracle.renounceRole(oracle.DEFAULT_ADMIN_ROLE(), deployer);
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock));
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        liquidator.grantRole(liquidator.DEFAULT_ADMIN_ROLE(), address(timelock));
        liquidator.renounceRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        // Post-condition: deployer no longer holds admin; timelock does.
        require(
            oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), address(timelock)),
            "Phase3: oracle admin != timelock"
        );
        require(
            !oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), deployer),
            "Phase3: deployer still oracle admin"
        );
        require(
            registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock)),
            "Phase3: registry admin != timelock"
        );
        require(
            !registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer),
            "Phase3: deployer still registry admin"
        );
        require(
            liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), address(timelock)),
            "Phase3: liq admin != timelock"
        );
        require(
            !liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer),
            "Phase3: deployer still liq admin"
        );

        string memory root = "phase3-handoff";
        string memory json = vm.serializeAddress(root, "FxTimelock", address(timelock));
        vm.writeJson(json, _phaseSubManifestPath("phase3-handoff"));

        console2.log("Phase3 done. FxTimelock", address(timelock));
        console2.log("Deployer admin renounced across oracle/registry/liquidator");
    }
}
