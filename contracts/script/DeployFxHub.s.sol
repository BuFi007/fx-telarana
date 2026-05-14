// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

import {MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

/// @notice Phase 0 Hub-side deployment. Run on Arc testnet (chain id 5042002).
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY    — funded with USDC on Arc for gas
///   ARC_USDC                — 0x3600000000000000000000000000000000000000
///   ARC_EURC                — 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
///   ARC_PYTH                — 0x2880aB155794e7179c9eE2e38200202908C17B43
///   ARC_MORPHO_BLUE         — Morpho Blue address on Arc (or self-deployed)
///   ARC_MORPHO_ADAPTIVE_IRM — AdaptiveCurveIrm address on Arc
///   ARC_CCTP_MESSAGE_TRANSMITTER — 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275
///   PYTH_FEED_USDC_USD      — 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a
///   PYTH_FEED_EURC_USD      — 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c
///   FX_HUB_LLTV             — e.g. 860000000000000000 (0.86e18)
contract DeployFxHub is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc            = vm.envAddress("ARC_USDC");
        address eurc            = vm.envAddress("ARC_EURC");
        address pyth            = vm.envAddress("ARC_PYTH");
        address morpho          = vm.envAddress("ARC_MORPHO_BLUE");
        address irm             = vm.envAddress("ARC_MORPHO_ADAPTIVE_IRM");
        address messageTransmitter = vm.envAddress("ARC_CCTP_MESSAGE_TRANSMITTER");
        bytes32 pythUsdcUsd     = vm.envBytes32("PYTH_FEED_USDC_USD");
        bytes32 pythEurcUsd     = vm.envBytes32("PYTH_FEED_EURC_USD");
        uint256 lltv            = vm.envUint("FX_HUB_LLTV");

        console2.log("deployer", deployer);

        vm.startBroadcast(pk);

        // 1) FxOracle (Pyth primary + RedStone secondary slot; 60s staleness; 50bps deviation; 30bps confidence)
        FxOracle oracle = new FxOracle(pyth, deployer, 60, 50, 30);
        oracle.setFeed(usdc, pythUsdcUsd);
        oracle.setFeed(eurc, pythEurcUsd);

        // 2) MorphoOracleAdapters (one per market direction)
        MorphoOracleAdapter adapterM1 = new MorphoOracleAdapter(address(oracle), eurc, usdc);
        MorphoOracleAdapter adapterM2 = new MorphoOracleAdapter(address(oracle), usdc, eurc);

        // 3) FxMarketRegistry — owner is deployer initially; transfer to timelock post-deploy
        FxMarketRegistry registry = new FxMarketRegistry(morpho, deployer);

        // 4) Create + register M1 (loan=EURC, collat=USDC) and M2 (loan=USDC, collat=EURC)
        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irm, lltv: lltv
        });
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irm, lltv: lltv
        });
        bytes32 m1Id = registry.createAndRegisterMarket(m1);
        bytes32 m2Id = registry.createAndRegisterMarket(m2);

        // 5) FxReceipts (1:1 ERC-4626 over each loan-side market position)
        MorphoMarketParams memory mpM1 = MorphoMarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irm, lltv: lltv
        });
        MorphoMarketParams memory mpM2 = MorphoMarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irm, lltv: lltv
        });
        FxReceipt fxEURC = new FxReceipt(IERC20(eurc), "fxEURC supply receipt", "fxEURC", morpho, mpM1);
        FxReceipt fxUSDC = new FxReceipt(IERC20(usdc), "fxUSDC supply receipt", "fxUSDC", morpho, mpM2);

        // 6) FxLiquidator
        FxLiquidator liquidator = new FxLiquidator(morpho, address(registry), address(oracle));

        // 7) FxHubMessageReceiver (CCTP V2 inbound)
        FxHubMessageReceiver receiver = new FxHubMessageReceiver(messageTransmitter, usdc, address(registry));

        vm.stopBroadcast();

        console2.log("FxOracle              ", address(oracle));
        console2.log("MorphoOracleAdapter M1", address(adapterM1));
        console2.log("MorphoOracleAdapter M2", address(adapterM2));
        console2.log("FxMarketRegistry      ", address(registry));
        console2.log("FxReceipt fxEURC      ", address(fxEURC));
        console2.log("FxReceipt fxUSDC      ", address(fxUSDC));
        console2.log("FxLiquidator          ", address(liquidator));
        console2.log("FxHubMessageReceiver  ", address(receiver));
        console2.logBytes32(m1Id);
        console2.logBytes32(m2Id);
    }
}
