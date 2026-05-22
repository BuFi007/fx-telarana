// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxV4RouterHarnessGateway} from "../test/utils/FxV4RouterHarnessGateway.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Deploy `FxV4RouterHarnessGateway` — the Gateway-aware exact-input
///         v4 router that forwards `hookData` to `TelaranaGatewayHubHook.beforeSwap`
///         so the PR-H8 intra-hook USDC liquidity path can be exercised.
///
/// Why this matters
/// ----------------
/// Wave N4 deployed `FxV4RouterHarness` for FxSwapHook's PMM path. It calls
/// `manager.swap(key, params, "")` — empty hookData. The TGH (Gateway hub
/// hook) requires `hookData` to carry the Circle Gateway attestation +
/// signature + GatewayMintContext so `beforeSwap` can call `gatewayMint(...)`
/// atomically.
///
/// `FxV4RouterHarnessGateway` accepts `bytes hookData` and forwards it to
/// `manager.swap(key, params, hookData)`. It also drains both currency
/// deltas via `TransientStateLibrary.currencyDelta` so the no-LP / zero-
/// liquidity Gateway-routed-swap case settles cleanly.
///
/// Wave N6 — proves the differentiator "Real-Time FX Swap Pool Using Gateway"
/// for the Hookathon submission.
///
/// Required env
/// ------------
///   PRIVATE_KEY — broadcast key (the Wave keeper EOA
///                 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69).
contract DeployFxV4RouterHarnessGateway is Script {
    /// @dev Uniswap v4 PoolManager singleton on Arc Testnet (chainId 5042002).
    /// Source of truth: defi-web-app packages/contracts/src/bento.ts.
    address constant POOL_MANAGER_ARC_TESTNET =
        0x3FA22b7Aeda9ebBe34732ea394f1711887363B34;

    function run() external returns (FxV4RouterHarnessGateway router) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));

        if (pk == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(pk);
        }

        router = new FxV4RouterHarnessGateway(IPoolManager(POOL_MANAGER_ARC_TESTNET));

        vm.stopBroadcast();

        console2.log("FxV4RouterHarnessGateway deployed at:", address(router));
        console2.log("PoolManager pinned:                  ", address(router.manager()));
    }
}
