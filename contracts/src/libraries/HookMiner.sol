// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Pure-Solidity CREATE2 salt miner for Uniswap v4 hook deploys.
///         The PoolManager checks `address(hook) & ALL_HOOK_MASK == flags`.
///         If your contract claims `beforeSwap = true` in `getHookPermissions`,
///         its deployed address MUST have bit 7 set in the low-order 14 bits.
///         This library brute-forces a salt that lands at such an address.
///
/// Brute force is acceptable for testnet because the search space is small
/// (target bits ~14, expected iterations ~16K). For mainnet, mine off-chain.
library HookMiner {
    /// @dev keccak256(0xff || deployer || salt || keccak256(creationCode))[12:32]
    function computeAddress(address deployer, bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(creationCode))
        ))));
    }

    /// @notice Find a salt whose CREATE2 address has the requested permission bits.
    /// @param deployer     The address that will call CREATE2 (e.g. Foundry's CREATE2 factory).
    /// @param flags        Permission-bit mask the deploy address must satisfy.
    /// @param creationCode Hook constructor bytecode + constructor args (use `abi.encodePacked`).
    /// @param maxLoops     Upper bound on salt search.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        uint256 maxLoops
    ) internal pure returns (address hookAddress, bytes32 salt) {
        uint160 mask = uint160(Hooks.ALL_HOOK_MASK);
        for (uint256 i = 0; i < maxLoops; ++i) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, creationCode);
            if (uint160(hookAddress) & mask == flags) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: exhausted maxLoops without a match");
    }

    /// @notice Convert a Hooks.Permissions struct into the flag bitfield.
    function flagsFromPermissions(Hooks.Permissions memory p) internal pure returns (uint160 flags) {
        if (p.beforeInitialize)               flags |= uint160(Hooks.BEFORE_INITIALIZE_FLAG);
        if (p.afterInitialize)                flags |= uint160(Hooks.AFTER_INITIALIZE_FLAG);
        if (p.beforeAddLiquidity)             flags |= uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        if (p.afterAddLiquidity)              flags |= uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        if (p.beforeRemoveLiquidity)          flags |= uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        if (p.afterRemoveLiquidity)           flags |= uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        if (p.beforeSwap)                     flags |= uint160(Hooks.BEFORE_SWAP_FLAG);
        if (p.afterSwap)                      flags |= uint160(Hooks.AFTER_SWAP_FLAG);
        if (p.beforeDonate)                   flags |= uint160(Hooks.BEFORE_DONATE_FLAG);
        if (p.afterDonate)                    flags |= uint160(Hooks.AFTER_DONATE_FLAG);
        if (p.beforeSwapReturnDelta)          flags |= uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        if (p.afterSwapReturnDelta)           flags |= uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        if (p.afterAddLiquidityReturnDelta)   flags |= uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        if (p.afterRemoveLiquidityReturnDelta) flags |= uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
    }
}
