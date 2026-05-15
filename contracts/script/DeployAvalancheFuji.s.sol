// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Morpho Blue + IrmMock are vendored at pragma 0.8.19 (strict). We deploy
// them via vm.deployCode so this script can stay at ^0.8.26 without
// forcing a single-compiler unit.
import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {FxTimelock} from "../src/governance/FxTimelock.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice fx-Telaraña hub deployment for Avalanche Fuji (chainId 43113).
///
/// Step 1 of the hub migration plan: Base Sepolia → Fuji → Arc.
///
/// Differences from `DeployBaseSepolia.s.sol`:
///   1. Morpho Blue is NOT deployed on Fuji — we self-deploy it with the
///      deployer as owner.
///   2. AdaptiveCurveIrm isn't available in the Morpho lib we vendor;
///      we use Morpho's bundled `IrmMock` for testnet. Self-deployed,
///      enabled on the new Morpho.
///   3. EURC is Circle's canonical Fuji deployment. Do not deploy MockEURC.
///   4. Pyth lives at the Fuji-specific 0x23f0e8FA…7509 (not the
///      mainnet 0x4305FB66… address).
///   5. CCTP V2 MessageTransmitter is at the same deterministic address
///      as every other V2 testnet (0xE737e5cE…E275).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY    Funded on Fuji
///
/// Optional env overrides:
///   FUJI_PYTH               default 0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509
///   FUJI_USDC               default 0x5425890298aed601595a70AB815c96711a31Bc65
///   FUJI_EURC               default 0x5E44db7996c682E92a960b65AC713a54AD815c6B
///   FUJI_CCTP_MT            default 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275
///   FX_HUB_LLTV             default 860000000000000000 (0.86e18)
contract DeployAvalancheFuji is Script {
    address constant DEFAULT_PYTH = 0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509;
    address constant DEFAULT_USDC = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address constant DEFAULT_EURC = 0x5E44db7996c682E92a960b65AC713a54AD815c6B;
    address constant DEFAULT_CCTP_MT = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

    bytes32 constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;

    bytes32 constant REDSTONE_USDC = bytes32("USDC");
    bytes32 constant REDSTONE_EURC = bytes32("EURC");

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Morpho Blue + IrmMock must be deployed first via `forge create`
        // (their 0.8.19 pragma can't share a compilation unit with this
        // ^0.8.26 script). Caller must enable the IRM + LLTV on Morpho
        // before running this script.
        address morphoAddr = vm.envAddress("MORPHO_FUJI");
        address irmAddr = vm.envAddress("IRM_FUJI");
        IMorpho morpho = IMorpho(morphoAddr);

        address pyth = vm.envOr("FUJI_PYTH", DEFAULT_PYTH);
        address usdc = vm.envOr("FUJI_USDC", DEFAULT_USDC);
        address eurc = vm.envOr("FUJI_EURC", DEFAULT_EURC);
        address cctpMt = vm.envOr("FUJI_CCTP_MT", DEFAULT_CCTP_MT);
        uint256 lltv = vm.envOr("FX_HUB_LLTV", uint256(860000000000000000));

        console2.log("deployer", deployer);
        console2.log("morpho  ", morphoAddr);
        console2.log("irm     ", irmAddr);
        console2.log("pyth    ", pyth);
        console2.log("usdc    ", usdc);
        console2.log("eurc    ", eurc);
        console2.log("cctp mt ", cctpMt);

        vm.startBroadcast(pk);

        // 4) FxOracle (Pyth primary on Fuji). Spec §8 production defaults:
        //    staleness=300s, deviation=50 bps, confidence=30 bps.
        FxOracle oracle = new FxOracle(pyth, deployer, 300, 50, 30);
        require(oracle.maxOracleAge() == 300, "deploy: maxOracleAge != 300");
        require(oracle.maxDeviationBps() == 50, "deploy: maxDeviationBps != 50");
        require(oracle.maxConfidenceBps() == 30, "deploy: maxConfidenceBps != 30");
        oracle.setFeed(usdc, PYTH_USDC_USD);
        oracle.setFeed(eurc, PYTH_EURC_USD);
        oracle.setRedstoneFeed(usdc, REDSTONE_USDC);
        oracle.setRedstoneFeed(eurc, REDSTONE_EURC);

        // 5) Morpho oracle adapters (per market direction).
        MorphoOracleAdapter adapterM1 = new MorphoOracleAdapter(address(oracle), eurc, usdc);
        MorphoOracleAdapter adapterM2 = new MorphoOracleAdapter(address(oracle), usdc, eurc);

        // 6) FxMarketRegistry on top of the self-deployed Morpho.
        FxMarketRegistry registry = new FxMarketRegistry(address(morpho), deployer);

        // 7) Markets.
        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irmAddr, lltv: lltv
        });
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irmAddr, lltv: lltv
        });
        bytes32 m1Id = registry.createAndRegisterMarket(m1);
        bytes32 m2Id = registry.createAndRegisterMarket(m2);

        // 8) FxReceipts.
        MorphoMarketParams memory mpM1 = MorphoMarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irmAddr, lltv: lltv
        });
        MorphoMarketParams memory mpM2 = MorphoMarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irmAddr, lltv: lltv
        });
        FxReceipt fxEURC = new FxReceipt(IERC20(eurc), "fxEURC supply receipt (Fuji)", "fxEURC", morphoAddr, mpM1);
        FxReceipt fxUSDC = new FxReceipt(IERC20(usdc), "fxUSDC supply receipt (Fuji)", "fxUSDC", morphoAddr, mpM2);

        // 9) Liquidator (with the Codex Drop-9 patch: maxRepayAssets + useVerified).
        FxLiquidator liquidator = new FxLiquidator(morphoAddr, address(registry), address(oracle), deployer);

        // 10) FxHubMessageReceiver (Codex-v4 patched — caller auth gate + USDC consumption invariant).
        FxHubMessageReceiver hubReceiver = new FxHubMessageReceiver(cctpMt, usdc, address(registry));

        // 11) FxTimelock + atomic admin handoff (spec §10.2).
        FxTimelock timelock = _deployTimelockAndHandoff(deployer, oracle, registry, liquidator);

        vm.stopBroadcast();

        _assertHandoff(address(timelock), deployer, oracle, registry, liquidator);

        console2.log("============================================");
        console2.log("fx-Telarana Fuji HUB deployment");
        console2.log("============================================");
        console2.log("MorphoBlue            ", morphoAddr);
        console2.log("IrmMock               ", irmAddr);
        console2.log("FxOracle              ", address(oracle));
        console2.log("MorphoOracleAdapter M1", address(adapterM1));
        console2.log("MorphoOracleAdapter M2", address(adapterM2));
        console2.log("FxMarketRegistry      ", address(registry));
        console2.log("FxReceipt fxEURC      ", address(fxEURC));
        console2.log("FxReceipt fxUSDC      ", address(fxUSDC));
        console2.log("FxLiquidator          ", address(liquidator));
        console2.log("FxHubMessageReceiver  ", address(hubReceiver));
        console2.log("FxTimelock            ", address(timelock));
        console2.log("EURC token            ", eurc);
        console2.log("CCTP MessageTransmitter", cctpMt);
        console2.log("CCTP V2 hub domain    ", uint256(1));
        console2.log("Market M1 id (EURC/USDC):");
        console2.logBytes32(m1Id);
        console2.log("Market M2 id (USDC/EURC):");
        console2.logBytes32(m2Id);
        console2.log("");
        console2.log("Next:");
        console2.log("  1. Update deployments/hub-config-fuji.json with FxHubMessageReceiver above");
        console2.log("  2. bun packages/sdk/scripts/migrate-hub.ts deployments/hub-config-fuji.json --execute");
    }

    function _deployTimelockAndHandoff(
        address deployer,
        FxOracle oracle,
        FxMarketRegistry registry,
        FxLiquidator liquidator
    ) internal returns (FxTimelock timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        timelock = new FxTimelock(24 hours, proposers, executors, address(0));

        oracle.grantRole(oracle.DEFAULT_ADMIN_ROLE(), address(timelock));
        oracle.renounceRole(oracle.DEFAULT_ADMIN_ROLE(), deployer);
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock));
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        liquidator.grantRole(liquidator.DEFAULT_ADMIN_ROLE(), address(timelock));
        liquidator.renounceRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _assertHandoff(
        address timelock,
        address deployer,
        FxOracle oracle,
        FxMarketRegistry registry,
        FxLiquidator liquidator
    ) internal view {
        require(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), timelock), "handoff: oracle admin != timelock");
        require(!oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), deployer), "handoff: deployer still oracle admin");
        require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), timelock), "handoff: registry admin != timelock");
        require(!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "handoff: deployer still registry admin");
        require(liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), timelock), "handoff: liq admin != timelock");
        require(!liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer), "handoff: deployer still liq admin");
    }
}
