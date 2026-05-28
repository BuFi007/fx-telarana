// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {AssetRegistry} from "../src/hub/AssetRegistry.sol";

/// @title DeployAssetRegistry
/// @notice Deploys AssetRegistry on the current chain and seeds it from a
///         JSON config under `script/configs/`. One script, two environments.
///
///         Usage:
///           DEPLOY_ENV=testnet forge script script/DeployAssetRegistry.s.sol \
///             --rpc-url <hub-rpc> --private-key $KEY --broadcast
///
///           DEPLOY_ENV=mainnet forge script script/DeployAssetRegistry.s.sol \
///             --rpc-url <hub-rpc> --private-key $KEY --broadcast
///
///         Optional env: ASSET_REGISTRY_ADMIN — defaults to msg.sender.
contract DeployAssetRegistry is Script {
    using stdJson for string;

    function run() public {
        string memory env = vm.envOr("DEPLOY_ENV", string("testnet"));
        require(
            keccak256(bytes(env)) == keccak256("testnet") || keccak256(bytes(env)) == keccak256("mainnet"),
            "DEPLOY_ENV must be 'testnet' or 'mainnet'"
        );

        string memory configPath = string.concat("script/configs/", env, ".json");
        string memory config = vm.readFile(configPath);

        uint256 currentChainId = block.chainid;
        address admin = vm.envOr("ASSET_REGISTRY_ADMIN", msg.sender);

        console2.log("DeployAssetRegistry");
        console2.log("  environment:", env);
        console2.log("  chain id   :", currentChainId);
        console2.log("  admin      :", admin);

        vm.startBroadcast();

        AssetRegistry registry = new AssetRegistry(admin);
        console2.log("AssetRegistry deployed at:", address(registry));

        // DRY: list the symbols once. testnet has 4 extras (MXNB/AUDF/QCAD/cirBTC).
        _registerAsset(registry, config, "USDC", currentChainId);
        _registerAsset(registry, config, "EURC", currentChainId);
        _registerAsset(registry, config, "JPYC", currentChainId);

        if (keccak256(bytes(env)) == keccak256("testnet")) {
            _registerAsset(registry, config, "MXNB", currentChainId);
            _registerAsset(registry, config, "AUDF", currentChainId);
            _registerAsset(registry, config, "QCAD", currentChainId);
            _registerAsset(registry, config, "cirBTC", currentChainId);
        } else {
            _registerAsset(registry, config, "MXNB", currentChainId);
            _registerAsset(registry, config, "AUDF", currentChainId);
            _registerAsset(registry, config, "QCAD", currentChainId);
        }

        vm.stopBroadcast();
    }

    // ── Internals ──────────────────────────────────────────────────

    /// @dev Reads `$.assets.<symbol>` from the config, registers the asset, and
    ///      sets the per-chain token address if one is present for the current
    ///      chain. JSON path probing uses an external `try` so a missing key
    ///      degrades to a console log instead of reverting the whole deploy.
    function _registerAsset(
        AssetRegistry registry,
        string memory config,
        string memory symbol,
        uint256 chainId
    ) internal {
        string memory base = string.concat("$.assets.", symbol);

        uint256 decimals = config.readUint(string.concat(base, ".decimals"));
        string memory strategyStr = config.readString(string.concat(base, ".bridgeStrategy"));
        uint256 homeChain = config.readUint(string.concat(base, ".liquidityHomeChainId"));

        AssetRegistry.BridgeStrategy strategy = _parseStrategy(strategyStr);
        bytes32 key = registry.registerAsset(symbol, uint8(decimals), strategy, homeChain);

        console2.log("  registered:", symbol);
        console2.log("    decimals :", decimals);
        console2.log("    strategy :", strategyStr);
        console2.log("    homeChain:", homeChain);

        // Per-chain token address (best effort — missing key is fine, asset may not be on this chain).
        string memory addrPath = string.concat(base, ".addresses.", vm.toString(chainId));
        if (config.keyExists(addrPath)) {
            address tokenAddr = config.readAddress(addrPath);
            if (tokenAddr != address(0)) {
                registry.setChainAddress(key, chainId, tokenAddr);
                console2.log("    addr@chain set:", tokenAddr);
            } else {
                console2.log("    addr@chain : 0x0 (placeholder, skipped)");
            }
        } else {
            console2.log("    addr@chain : not configured on this chain");
        }

        // Per-chain warp route (Hyperlane) — only present for assets we bridge.
        string memory warpPath = string.concat(base, ".hyperlaneWarpRoutes.", vm.toString(chainId));
        if (config.keyExists(warpPath)) {
            address warpAddr = config.readAddress(warpPath);
            if (warpAddr != address(0)) {
                registry.setBridgeContract(key, chainId, warpAddr);
                console2.log("    warpRoute  :", warpAddr);
            }
        }
    }

    function _parseStrategy(string memory s) internal pure returns (AssetRegistry.BridgeStrategy) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("None")) return AssetRegistry.BridgeStrategy.None;
        if (h == keccak256("CCTP")) return AssetRegistry.BridgeStrategy.CCTP;
        if (h == keccak256("CircleGateway")) return AssetRegistry.BridgeStrategy.CircleGateway;
        if (h == keccak256("Hyperlane")) return AssetRegistry.BridgeStrategy.Hyperlane;
        if (h == keccak256("Native")) return AssetRegistry.BridgeStrategy.Native;
        revert(string.concat("Unknown bridgeStrategy: ", s));
    }
}
