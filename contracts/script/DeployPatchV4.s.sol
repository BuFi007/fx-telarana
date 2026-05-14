// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice v4 patch redeploy following the Codex adversarial review.
///         Replaces FxMarketRegistry (caller-auth gate on
///         withdraw/withdrawCollateral/borrow), FxHubMessageReceiver
///         (USDC consumption invariant) and FxLiquidator (re-bound to
///         the new registry).
///
/// FxOracle, MorphoOracleAdapter{M1,M2}, FxReceipt{USDC,EURC},
/// FxSwapHook all stay at their v3 addresses — none of them depend on
/// the patched contracts' interfaces.
///
/// Required env (no defaults — caller must supply them so the script
/// is hard to misuse against a different network):
///   DEPLOYER_PRIVATE_KEY
///   V3_ORACLE
///   V3_ADAPTER_M1
///   V3_ADAPTER_M2
///   USDC
///   EURC
///   MORPHO
///   ADAPTIVE_IRM
///   CCTP_MT
///   LLTV
contract DeployPatchV4 is Script {
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer  = vm.addr(pk);
        address oracle    = vm.envAddress("V3_ORACLE");
        address adapterM1 = vm.envAddress("V3_ADAPTER_M1");
        address adapterM2 = vm.envAddress("V3_ADAPTER_M2");
        address usdc      = vm.envAddress("USDC");
        address eurc      = vm.envAddress("EURC");
        address morpho    = vm.envAddress("MORPHO");
        address irm       = vm.envAddress("ADAPTIVE_IRM");
        address cctpMt    = vm.envAddress("CCTP_MT");
        uint256 lltv      = vm.envUint("LLTV");

        console2.log("deployer   ", deployer);
        console2.log("oracle (v3)", oracle);
        console2.log("morpho     ", morpho);

        vm.startBroadcast(pk);

        // 1) New FxMarketRegistry
        FxMarketRegistry registry = new FxMarketRegistry(morpho, deployer);

        // 2) Register the EXISTING v3 markets via registerMarket — they
        //    already live on Morpho with these exact MarketParams, so we
        //    don't call createMarket again. registerMarket just records
        //    the (loan, collateral) → id mapping inside our registry.
        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: eurc,
            collateralToken: usdc,
            oracle: adapterM1,
            irm: irm,
            lltv: lltv
        });
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: usdc,
            collateralToken: eurc,
            oracle: adapterM2,
            irm: irm,
            lltv: lltv
        });
        bytes32 m1Id = registry.registerMarket(m1);
        bytes32 m2Id = registry.registerMarket(m2);

        // 3) New FxLiquidator (rebind to the patched registry)
        FxLiquidator liquidator = new FxLiquidator(morpho, address(registry), oracle);

        // 4) New FxHubMessageReceiver (CCTP V2 inbound) bound to the patched registry
        FxHubMessageReceiver receiver = new FxHubMessageReceiver(cctpMt, usdc, address(registry));

        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("fx-Telarana v4 PATCH deployment");
        console2.log("============================================");
        console2.log("FxMarketRegistry (v4)    ", address(registry));
        console2.log("FxLiquidator (v4)        ", address(liquidator));
        console2.log("FxHubMessageReceiver (v4)", address(receiver));
        console2.log("Market M1 (EURC/USDC)    ");
        console2.logBytes32(m1Id);
        console2.log("Market M2 (USDC/EURC)    ");
        console2.logBytes32(m2Id);
    }
}
