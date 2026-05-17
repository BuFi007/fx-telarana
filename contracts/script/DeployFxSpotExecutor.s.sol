// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxSpotExecutor} from "../src/spot/FxSpotExecutor.sol";

/// @notice Per-chain deploy of FxSpotExecutor (Phase A v0.2).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   USDC                    — local USDC address
///   FX_ORACLE               — local FxOracle address (Pyth + optional RedStone)
///   TELARANA_GATEWAY_HUB_HOOK — local TGH address that delivers USDC for spot-fx
///
/// Optional env:
///   INITIAL_ADMIN           — defaults to deployer
///   DEFAULT_SPREAD_BPS      — defaults to 5 (0.05%)
///
/// Post-deploy wiring (manual, owner-signed):
///   1. setTokenEnabled(<target_token>, true) — stores tokenOut decimals
///   2. addLiquidity(<target_token>, <seed_amount>) — owner seeds reserves
///   3. grantRole(EXECUTOR_ROLE, <keeper_eoa>) on FxSpotExecutor
///   4. grantRole(EXECUTOR_ROLE, <FxSpotExecutor_addr>) on TGH — so
///      executor can call markGatewayAtomicFxSwapSettled
///   5. Configure a NEW TGH route id whose destinationHub = FxSpotExecutor
///      (separate from the MINT_TO_HUB route whose destinationHub is the
///      FxHubMessageReceiver)
///   6. Configure BUFX side with the new spot-fx routeId via setTelaranaRoute
contract DeployFxSpotExecutor is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc = vm.envAddress("USDC");
        address oracle = vm.envAddress("FX_ORACLE");
        address tgh = vm.envAddress("TELARANA_GATEWAY_HUB_HOOK");
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);
        uint256 defaultSpread = vm.envOr("DEFAULT_SPREAD_BPS", uint256(5));

        console2.log("============================================");
        console2.log("Deploying FxSpotExecutor (Phase A v0.2)");
        console2.log("============================================");
        console2.log("deployer        ", deployer);
        console2.log("usdc            ", usdc);
        console2.log("oracle          ", oracle);
        console2.log("tgh             ", tgh);
        console2.log("initialAdmin    ", initialAdmin);
        console2.log("defaultSpreadBps", defaultSpread);

        vm.startBroadcast(pk);
        FxSpotExecutor executor = new FxSpotExecutor(usdc, oracle, tgh, initialAdmin, defaultSpread);
        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("FxSpotExecutor", address(executor));
        console2.log("============================================");
        console2.log("");
        console2.log("Next steps (do NOT skip):");
        console2.log("  1. setTokenEnabled(<tokenOut>, true)");
        console2.log("  2. addLiquidity(<tokenOut>, <seed>)");
        console2.log("  3. FxSpotExecutor.grantRole(EXECUTOR_ROLE, <keeper>)");
        console2.log("  4. TGH.grantRole(EXECUTOR_ROLE, <FxSpotExecutor>)");
        console2.log("  5. Configure new TGH route with destinationHub = FxSpotExecutor");
        console2.log("  6. Configure BUFX TelaranaRouter with new spot-fx routeId");
    }
}
