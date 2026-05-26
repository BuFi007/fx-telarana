// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {LiquidationRouter} from "../src/perp/LiquidationRouter.sol";

/// @notice Deploys the BUFX perps LiquidationRouter on Arc.
contract DeployLiquidationRouter is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_ARC_LIQUIDATION_ENGINE = 0xA70aA9B3bCD3BB829B2E8aF29d8A48f5e09f50E5;
    address internal constant DEFAULT_ARC_USDC = 0x3600000000000000000000000000000000000000;

    error WrongChain(uint256 chainId);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address engine = vm.envOr("ARC_PERP_LIQUIDATION", DEFAULT_ARC_LIQUIDATION_ENGINE);
        address usdc = vm.envOr("ARC_USDC", DEFAULT_ARC_USDC);

        console2.log("============================================");
        console2.log("Deploying LiquidationRouter");
        console2.log("============================================");
        console2.log("chainId     ", block.chainid);
        console2.log("deployer    ", deployer);
        console2.log("engine      ", engine);
        console2.log("rewardToken ", usdc);

        vm.startBroadcast(pk);
        LiquidationRouter router = new LiquidationRouter(engine, usdc);
        vm.stopBroadcast();

        string memory defaultPath =
            string.concat("../deployments/liquidation-router-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("LIQUIDATION_ROUTER_PATH", defaultPath);
        _writeManifest(path, deployer, address(router), engine, usdc);

        console2.log("LiquidationRouter", address(router));
        console2.log("manifest", path);
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address router,
        address engine,
        address rewardToken
    ) internal {
        string memory root = "liquidationRouter";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedBlockNumber", block.number);
        vm.serializeUint(root, "deployedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "LiquidationRouter", router);
        vm.serializeAddress(root, "FxLiquidationEngine", engine);
        string memory json = vm.serializeAddress(root, "rewardToken", rewardToken);
        vm.writeJson(json, path);
    }
}
