// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {BasketDeployBase} from "./BasketDeployBase.sol";

import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FxOracle} from "../../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../../src/hub/FxMarketRegistry.sol";
import {FxLiquidator} from "../../src/hub/FxLiquidator.sol";
import {FxHubMessageReceiver} from "../../src/hub/FxHubMessageReceiver.sol";
import {MockStablecoin} from "../../src/test-helpers/MockStablecoin.sol";
import {MockPyth} from "../../test/mocks/MockPyth.sol";

/// @notice Phase 1: deploys the core stack (USDC mock, MockPyth, PoolManager,
///         PoolSwapTest, FxOracle, FxMarketRegistry, FxLiquidator,
///         FxHubMessageReceiver). Emits `phase1-core.json` sub-manifest.
///
/// Tenderly Pro TUs budget: ~10 contract deploys + ~3 config txs. Fits.
contract Phase1_Core is BasketDeployBase {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address morphoAddr = vm.envOr("TENDERLY_BASKET_MORPHO", DEFAULT_FUJI_MORPHO);
        address irm = vm.envOr("TENDERLY_BASKET_IRM", DEFAULT_FUJI_IRM);
        address cctpMt = vm.envOr("TENDERLY_BASKET_CCTP_MT", DEFAULT_FUJI_CCTP_MT);

        // Allow-list: Avalanche Fuji L1 (43113), Arc Testnet (5042002), or the
        // Tenderly virtual Fuji testnet (also 43113). Any other chain is a
        // testnet-only-rule violation per docs/TENDERLY_CLAUDE_HANDOFF_PROMPT.md.
        require(
            block.chainid == 43113 || block.chainid == 5042002,
            "Phase1: testnet-only (Fuji 43113 or Arc 5042002)"
        );
        require(morphoAddr.code.length != 0, "Phase1: Morpho missing on chain");
        require(irm.code.length != 0, "Phase1: IRM missing on chain");
        require(HOOK_CREATE2_FACTORY.code.length != 0, "Phase1: CREATE2 factory missing");

        vm.startBroadcast(pk);

        IMorpho morpho = IMorpho(morphoAddr);
        _ensureMorphoConfig(morpho, irm, LLTV, deployer);

        MockPyth pyth = new MockPyth();
        MockStablecoin usdc = _deployToken("Tenderly USDC", "USDC", 6, deployer);
        _setPrice(pyth, FEED_USDC, 1_00_000_000);

        PoolManager poolManager = new PoolManager(deployer);
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        FxOracle oracle = new FxOracle(address(pyth), deployer, 300, 50, 30);
        oracle.setPythFeedConfig(address(usdc), FEED_USDC, false);
        oracle.setRedstoneFeed(address(usdc), bytes32("USDC"));

        FxMarketRegistry registry = new FxMarketRegistry(address(morpho), deployer);
        FxLiquidator liquidator = new FxLiquidator(address(morpho), address(registry), address(oracle), deployer);
        FxHubMessageReceiver receiver = new FxHubMessageReceiver(cctpMt, address(usdc), address(registry));

        vm.stopBroadcast();

        // Post-condition: spec §8 oracle defaults stuck.
        require(oracle.maxOracleAge() == 300, "Phase1: maxOracleAge != 300");
        require(oracle.maxDeviationBps() == 50, "Phase1: maxDeviationBps != 50");
        require(oracle.maxConfidenceBps() == 30, "Phase1: maxConfidenceBps != 30");

        string memory root = "phase1-core";
        vm.serializeString(root, "network", "tenderly-avalanche-fuji-basket");
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "MorphoBlue", morphoAddr);
        vm.serializeAddress(root, "Irm", irm);
        vm.serializeAddress(root, "CctpMessageTransmitterV2", cctpMt);
        vm.serializeAddress(root, "MockPyth", address(pyth));
        vm.serializeAddress(root, "USDC", address(usdc));
        vm.serializeAddress(root, "PoolManager", address(poolManager));
        vm.serializeAddress(root, "PoolSwapTest", address(swapRouter));
        vm.serializeAddress(root, "FxOracle", address(oracle));
        vm.serializeAddress(root, "FxMarketRegistry", address(registry));
        vm.serializeAddress(root, "FxLiquidator", address(liquidator));
        vm.serializeAddress(root, "FxHubMessageReceiver", address(receiver));
        string memory json = vm.serializeBytes32(root, "feed_USDC", FEED_USDC);

        vm.writeJson(json, _phaseSubManifestPath("phase1-core"));

        console2.log("Phase1 done. FxOracle", address(oracle));
        console2.log("Phase1 done. FxMarketRegistry", address(registry));
    }
}
