// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Deploy the canonical Uniswap v4 `PoolSwapTest` periphery router
///         (from the v4-core `src/test/` directory) on Arc Testnet so EOAs
///         can drive `PoolManager.swap` via the unlock/callback dance.
///
/// Why this matters
/// ----------------
/// `PoolManager.unlock(bytes)` re-enters `IUnlockCallback.unlockCallback(data)`
/// on `msg.sender`. EOAs can't satisfy that interface — they need a contract
/// router. Universal Router would be the preferred entry point per the
/// Uniswap v4 SDK, but is NOT deployed on Arc Testnet (verified 2026-05-21
/// against https://developers.uniswap.org/contracts/v4/deployments). Until
/// a Universal Router lands on Arc, `PoolSwapTest` is the canonical
/// fallback shipped inside v4-core itself.
///
/// Wave N2a — closes the first M4 Phase-D blocker. Pinned to defi-web-app
/// via `getV4SwapRouterAddress(5042002)` (see PR #91 helper).
///
/// Required env
/// ------------
///   PRIVATE_KEY — broadcast key (the Wave keeper EOA
///                 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69, funded with
///                 Arc native USDC for gas).
///
/// The PoolManager address is pinned in-line to the canonical Arc Testnet
/// singleton (mirrored from `deployments/arc-testnet.json` and
/// `defi-web-app/packages/contracts/src/bento.ts` `BENTO_ARC_TESTNET_DEPLOYMENT`).
contract DeployPoolSwapTest is Script {
    /// @dev Uniswap v4 PoolManager singleton on Arc Testnet (chainId 5042002).
    /// Source of truth: defi-web-app packages/contracts/src/bento.ts.
    address constant POOL_MANAGER_ARC_TESTNET =
        0x3FA22b7Aeda9ebBe34732ea394f1711887363B34;

    function run() external returns (PoolSwapTest router) {
        // Forge's --private-key flag populates this slot via vm.envUint
        // when the flag is set. When run with --private-key directly,
        // vm.startBroadcast() picks up the key from the flag without
        // needing an env read. Keeping the env read for parity with
        // sibling deploy scripts (DeployFxSwapHook, DeployTelaranaGatewayHubHook).
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));

        if (pk == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(pk);
        }

        router = new PoolSwapTest(IPoolManager(POOL_MANAGER_ARC_TESTNET));

        vm.stopBroadcast();

        console2.log("PoolSwapTest deployed:", address(router));
        console2.log("  poolManager (arg)  :", POOL_MANAGER_ARC_TESTNET);
        console2.log("  manager()          :", address(router.manager()));
    }
}
