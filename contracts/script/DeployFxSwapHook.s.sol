// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Mine a CREATE2 salt + deploy FxSwapHook at an address whose low-order
///         bits encode the hook's permissions, so the Uniswap v4 PoolManager
///         can call our beforeSwap / afterSwap / beforeAddLiquidity / etc.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   POOL_MANAGER          — Uniswap v4 PoolManager on the target chain
///   FX_ORACLE             — already-deployed FxOracle address
///   FX_MARKET_REGISTRY    — already-deployed FxMarketRegistry
///   MORPHO_BLUE           — Morpho Blue address on the target chain
///   HOOK_OWNER            — initial owner of the hook (e.g. deployer or timelock)
///   POOL_TOKEN0           — sorted-lower token (USDC on Arc + Base Sepolia)
///   POOL_TOKEN1           — sorted-higher token (EURC)
///
/// Uses the standard Foundry CREATE2 factory (deployed at
/// `0x4e59b44847b379578588920cA78FbF26c0B4956C` on every EVM chain).
contract DeployFxSwapHook is Script {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address oracle      = vm.envAddress("FX_ORACLE");
        address registry    = vm.envAddress("FX_MARKET_REGISTRY");
        address morpho      = vm.envAddress("MORPHO_BLUE");
        address hookOwner   = vm.envAddress("HOOK_OWNER");
        address token0      = vm.envAddress("POOL_TOKEN0");
        address token1      = vm.envAddress("POOL_TOKEN1");
        require(token0 < token1, "token0 must sort before token1");

        // 1) Pack constructor args + creation code
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(poolManager, oracle, registry, hookOwner, token0, token1, morpho)
        );

        // 2) Compute target flags from FxSwapHook.getHookPermissions() (mirror in code)
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // 3) Mine a salt
        (address expected, bytes32 salt) = HookMiner.find(FACTORY, flags, creationCode, 200_000);
        console2.log("mined hook address  ", expected);
        console2.logBytes32(salt);

        // 4) Deploy via CREATE2
        vm.startBroadcast(pk);
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(salt, creationCode));
        require(ok, "CREATE2 deploy failed");
        address actual;
        assembly {
            actual := mload(add(ret, 20))
        }
        // CREATE2 factory returns the 20-byte address as the call's return data
        vm.stopBroadcast();

        require(actual == expected, "deployed address != mined address");

        console2.log("=================================");
        console2.log("FxSwapHook deployed:", actual);
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("deployer (CREATE2 EOA):", deployer);
        console2.log("CREATE2 factory:       ", FACTORY);
        console2.log("pool manager:          ", poolManager);
        console2.log("oracle:                ", oracle);
        console2.log("registry:              ", registry);
        console2.log("owner:                 ", hookOwner);
        console2.log("=================================");
        console2.log("Next: create a v4 pool with hook = above address (Universal Router or PoolManager.initialize).");
    }
}
