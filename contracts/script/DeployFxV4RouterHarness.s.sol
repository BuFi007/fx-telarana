// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxV4RouterHarness} from "../test/utils/FxV4RouterHarness.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Deploy `FxV4RouterHarness` — the PMM-aware exact-input v4 router —
///         on Arc Testnet so EOAs can drive `PoolManager.swap` through
///         FxSwapHook without reverting at `inputCurrency.take(POOL_MANAGER,
///         hook, amountIn)` inside `beforeSwap`.
///
/// Why this matters
/// ----------------
/// Wave N2a deployed the canonical Uniswap v4 `PoolSwapTest` router. That
/// router is the *v4-LP* shape — it settles the user's input AFTER
/// `manager.swap` returns. FxSwapHook is a *PMM* — during `beforeSwap` it
/// pulls the specified input out of PoolManager
/// (`inputCurrency.take(POOL_MANAGER, hook, amountIn)` at FxSwapHook.sol L731).
/// With PoolSwapTest, PoolManager has 0 USDC at that moment → revert.
///
/// `FxV4RouterHarness` (`contracts/test/utils/FxV4RouterHarness.sol`) instead
/// calls `_settleFrom(input, sender, amountIn)` BEFORE `manager.swap`, which
/// is what the PMM custom-accounting shape requires.
///
/// PoolSwapTest is left on-chain (deployed in N2a at 0x60004B…11fa) as a
/// deprecated periphery for v4-LP-shape pools, but is NO LONGER pinned in
/// defi-web-app's `V4SwapRouter` slot.
///
/// Wave N4 — closes N3's swap-leg revert (PR #97).
///
/// Required env
/// ------------
///   PRIVATE_KEY — broadcast key (the Wave keeper EOA
///                 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69, funded with
///                 Arc native USDC for gas; ~22.2 USDC remaining post-N3).
contract DeployFxV4RouterHarness is Script {
    /// @dev Uniswap v4 PoolManager singleton on Arc Testnet (chainId 5042002).
    /// Source of truth: defi-web-app packages/contracts/src/bento.ts.
    address constant POOL_MANAGER_ARC_TESTNET =
        0x3FA22b7Aeda9ebBe34732ea394f1711887363B34;

    function run() external returns (FxV4RouterHarness router) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));

        if (pk == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(pk);
        }

        router = new FxV4RouterHarness(IPoolManager(POOL_MANAGER_ARC_TESTNET));

        vm.stopBroadcast();

        console2.log("FxV4RouterHarness deployed:", address(router));
        console2.log("  poolManager (arg)       :", POOL_MANAGER_ARC_TESTNET);
        console2.log("  manager()               :", address(router.manager()));
    }
}
