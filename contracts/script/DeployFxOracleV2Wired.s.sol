// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxOracleV2} from "../src/hub/FxOracleV2.sol";

/// @notice Pass 2a — deploy the consolidated FxOracleV2 (Pyth + inversion + Chainlink fallback)
///         and wire the Pyth feeds for USDC/EURC/AUDF + MXNB (USD/MXN INVERTED). QCAD has no Pyth
///         CAD feed on Arc — it gets a self-published Chainlink-compatible manual feed in a later step.
///         Deployed with admin = DEPLOYER (so wiring is atomic), then admin handed to KEEPER.
contract DeployFxOracleV2Wired is Script {
    address constant PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address constant KEEPER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address constant MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;

    // Pyth feed ids (chain-agnostic), matching the live oracle / pusher.
    bytes32 constant USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;
    bytes32 constant AUD_USD = 0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80;
    bytes32 constant USD_MXN = 0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        // (pyth, admin, maxOracleAge, maxDevBps, maxConfBps, chainlinkMaxAge)
        FxOracleV2 v2 = new FxOracleV2(PYTH, deployer, 60, 50, 30, 3600);

        v2.setPythFeedConfig(USDC, USDC_USD, false);
        v2.setPythFeedConfig(EURC, EURC_USD, false);
        v2.setPythFeedConfig(AUDF, AUD_USD, false);
        v2.setPythFeedConfig(MXNB, USD_MXN, true); // INVERTED: Pyth gives MXN per USD; pool needs USD per MXN

        // Hand DEFAULT_ADMIN to KEEPER, drop the deployer's admin.
        bytes32 adminRole = 0x00;
        v2.grantRole(adminRole, KEEPER);
        v2.renounceRole(adminRole, deployer);
        vm.stopBroadcast();

        console2.log("FX_ORACLE_V2", address(v2));
    }
}
