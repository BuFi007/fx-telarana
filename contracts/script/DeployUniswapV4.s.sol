// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Deploy Uniswap v4 PoolManager on Arc Testnet and Avalanche Fuji.
/// Uniswap v4 is not officially deployed on either chain. The CREATE2
/// deployer exists on both, so deterministic addresses are possible.
///
/// Usage:
///   # Arc Testnet
///   forge script script/DeployUniswapV4.s.sol \
///     --rpc-url https://rpc.drpc.testnet.arc.network \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast --verify
///
///   # Avalanche Fuji
///   forge script script/DeployUniswapV4.s.sol \
///     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast
contract DeployUniswapV4 is Script {
    function run() public {
        vm.startBroadcast();

        PoolManager pm = new PoolManager(msg.sender);
        console2.log("PoolManager deployed at:", address(pm));

        vm.stopBroadcast();
    }
}
