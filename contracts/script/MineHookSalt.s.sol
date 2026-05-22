// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../lib/openzeppelin-uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";

import {TelaranaGatewayHubHook} from "../src/hub/TelaranaGatewayHubHook.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";

/// @notice PR-H8 / Wave L2 — mine a CREATE2 salt for TelaranaGatewayHubHook
///         whose deployed address encodes the v4 hook permission flags in
///         its low 14 bits. The PoolManager rejects any swap on a pool
///         whose hook address does not encode `getHookPermissions()`.
///
/// Required env:
///   USDC           — USDC token address on this chain
///   GATEWAY_MINTER — Circle GatewayMinter address on this chain
///   POOL_MANAGER   — Uniswap v4 PoolManager address on this chain
///   INITIAL_ADMIN  — admin to grant DEFAULT_ADMIN_ROLE / OPERATIONS_ROLE / EXECUTOR_ROLE
///
/// Optional env:
///   CREATE2_DEPLOYER — defaults to 0x4e59b44847b379578588920cA78FbF26c0B4956C
///                      (canonical Foundry-default CREATE2 Deployer Proxy)
///
/// Output:
///   Prints the mined `(hookAddress, salt)`. Pass this salt as the
///   `--salt` argument to your CREATE2 deploy (or use a small
///   `Create2Deployer` wrapper that takes `bytes32 salt`).
contract MineHookSalt is Script {
    /// @dev Canonical CREATE2 Deployer Proxy used by forge-std / OZ / Uniswap.
    ///      Source: https://github.com/Arachnid/deterministic-deployment-proxy
    address internal constant DEFAULT_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external view {
        address usdc = vm.envAddress("USDC");
        address gatewayMinter = vm.envAddress("GATEWAY_MINTER");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address initialAdmin = vm.envAddress("INITIAL_ADMIN");
        address deployer = vm.envOr("CREATE2_DEPLOYER", DEFAULT_CREATE2_DEPLOYER);

        // Match `getHookPermissions()` on the deployed contract.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        bytes memory creationCode = type(TelaranaGatewayHubHook).creationCode;
        bytes memory ctorArgs = abi.encode(usdc, gatewayMinter, poolManager, initialAdmin);

        (address hookAddress, bytes32 salt) = HookMiner.find(deployer, flags, creationCode, ctorArgs);

        console2.log("============================================");
        console2.log("Mined TelaranaGatewayHubHook salt");
        console2.log("============================================");
        console2.log("deployer    ", deployer);
        console2.log("usdc        ", usdc);
        console2.log("gateway     ", gatewayMinter);
        console2.log("poolManager ", poolManager);
        console2.log("initAdmin   ", initialAdmin);
        console2.log("flags (hex) ");
        console2.logBytes32(bytes32(uint256(flags)));
        console2.log("hookAddress ", hookAddress);
        console2.log("salt        ");
        console2.logBytes32(salt);
        console2.log("");
        console2.log("Sanity check: low 14 bits of hookAddress");
        console2.logBytes32(bytes32(uint256(uint160(hookAddress) & uint160(Hooks.ALL_HOOK_MASK))));
        console2.log("");
        console2.log("Broadcast with this salt via Create2 Deployer Proxy.");
    }

    /// @notice Mine a CREATE2 salt for FxSwapHook. Permission flags:
    ///         beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap |
    ///         afterSwap | beforeSwapReturnDelta. Low 14 bits must = 0xAC8.
    ///
    /// Required env:
    ///   POOL_MANAGER       — Uniswap v4 PoolManager
    ///   FX_ORACLE          — already-deployed FxOracle
    ///   FX_MARKET_REGISTRY — already-deployed FxMarketRegistry
    ///   MORPHO_BLUE        — Morpho Blue
    ///   HOOK_OWNER         — initial owner
    ///   POOL_TOKEN0        — sorted-lower token
    ///   POOL_TOKEN1        — sorted-higher token
    ///
    /// Optional env:
    ///   CREATE2_DEPLOYER   — defaults to canonical proxy
    function runFxSwap() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address oracle      = vm.envAddress("FX_ORACLE");
        address registry    = vm.envAddress("FX_MARKET_REGISTRY");
        address morpho      = vm.envAddress("MORPHO_BLUE");
        address hookOwner   = vm.envAddress("HOOK_OWNER");
        address token0      = vm.envAddress("POOL_TOKEN0");
        address token1      = vm.envAddress("POOL_TOKEN1");
        address deployer    = vm.envOr("CREATE2_DEPLOYER", DEFAULT_CREATE2_DEPLOYER);
        require(token0 < token1, "token0 must sort before token1");

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory creationCode = type(FxSwapHook).creationCode;
        bytes memory ctorArgs = abi.encode(poolManager, oracle, registry, hookOwner, token0, token1, morpho);

        (address hookAddress, bytes32 salt) = HookMiner.find(deployer, flags, creationCode, ctorArgs);

        console2.log("============================================");
        console2.log("Mined FxSwapHook salt");
        console2.log("============================================");
        console2.log("deployer    ", deployer);
        console2.log("poolManager ", poolManager);
        console2.log("oracle      ", oracle);
        console2.log("registry    ", registry);
        console2.log("morpho      ", morpho);
        console2.log("hookOwner   ", hookOwner);
        console2.log("token0      ", token0);
        console2.log("token1      ", token1);
        console2.log("flags (hex) ");
        console2.logBytes32(bytes32(uint256(flags)));
        console2.log("hookAddress ", hookAddress);
        console2.log("salt        ");
        console2.logBytes32(salt);
        console2.log("");
        console2.log("Sanity check: low 14 bits of hookAddress");
        console2.logBytes32(bytes32(uint256(uint160(hookAddress) & uint160(Hooks.ALL_HOOK_MASK))));
        console2.log("");
        console2.log("Broadcast with DeployFxSwapHook (it mines + broadcasts) or via CREATE2 proxy with this salt.");
    }
}
