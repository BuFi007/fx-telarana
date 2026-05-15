// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {FxTimelock} from "../src/governance/FxTimelock.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice fx-Telarana Hub deploy on **Arc testnet (chainId 5042002)**.
///
/// Arc-specific notes baked in:
///   * USDC is the native gas token. Deployer wallet must be funded via
///     https://faucet.circle.com before running this script.
///   * `msg.value` and `address.balance` on Arc are still 18-decimal native units
///     (the native gas token is USDC under the hood, but the EVM unit is unchanged).
///     Pyth's `getUpdateFee` returns 18-decimal native units — our payable flow
///     in FxOracle.getMidWithUpdate works without modification.
///   * Arc targets the **Prague** EVM hardfork (superset of Cancun). Our cancun-
///     compiled bytecode runs natively.
///   * Sub-second finality on Arc means oracle update windows are tight. The
///     `getMidWithUpdate` Pyth pull is safe inside the same tx as the action.
///   * Canonical Circle-deployed EURC exists on Arc — no MockEURC required.
///
/// Required env (set these before running):
///   ARC_TESTNET_RPC_URL              — defaults to https://rpc.testnet.arc.network
///   DEPLOYER_PRIVATE_KEY             — funded via faucet.circle.com
///   ARC_MORPHO_BLUE                  — Morpho Blue address on Arc (when published)
///   ARC_MORPHO_ADAPTIVE_IRM          — AdaptiveCurveIrm address on Arc (when published)
///
/// Pre-set defaults (verified Arc testnet addresses):
///   USDC, EURC, Pyth, CCTP V2 TokenMessenger, CCTP V2 MessageTransmitter
contract DeployArcTestnet is Script {
    // ── Verified Arc testnet defaults (chainId 5042002, CCTP domain 26) ────
    address constant DEFAULT_USDC                = 0x3600000000000000000000000000000000000000;
    address constant DEFAULT_EURC                = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant DEFAULT_PYTH                = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address constant DEFAULT_CCTP_TOKEN_MESSENGER     = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address constant DEFAULT_CCTP_MESSAGE_TRANSMITTER = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

    bytes32 constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;

    bytes32 constant REDSTONE_USDC = bytes32("USDC");
    bytes32 constant REDSTONE_EURC = bytes32("EURC");

    error MissingArcMorphoAddress();
    error MissingArcIrmAddress();

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc                = vm.envOr("ARC_USDC", DEFAULT_USDC);
        address eurc                = vm.envOr("ARC_EURC", DEFAULT_EURC);
        address pyth                = vm.envOr("ARC_PYTH", DEFAULT_PYTH);
        address messageTransmitter  = vm.envOr("ARC_CCTP_MESSAGE_TRANSMITTER", DEFAULT_CCTP_MESSAGE_TRANSMITTER);
        address morpho              = vm.envAddress("ARC_MORPHO_BLUE");
        address irm                 = vm.envAddress("ARC_MORPHO_ADAPTIVE_IRM");
        uint256 lltv                = vm.envOr("FX_HUB_LLTV", uint256(860000000000000000));

        if (morpho == address(0)) revert MissingArcMorphoAddress();
        if (irm == address(0)) revert MissingArcIrmAddress();

        console2.log("======== fx-Telarana Arc Testnet Deploy ========");
        console2.log("deployer", deployer);
        console2.log("morpho  ", morpho);
        console2.log("irm     ", irm);
        console2.log("pyth    ", pyth);
        console2.log("usdc    ", usdc);
        console2.log("eurc    ", eurc);
        console2.log("CCTP MT ", messageTransmitter);

        vm.startBroadcast(pk);

        // 1) FxOracle — Pyth primary + RedStone secondary. 24/7. Deployer is
        //    initial admin; DEFAULT_ADMIN_ROLE transfers to FxTimelock below.
        //    Spec §8 production defaults: staleness=300s, deviation=50 bps, confidence=30 bps.
        FxOracle oracle = new FxOracle(pyth, deployer, 300, 50, 30);
        require(oracle.maxOracleAge() == 300, "deploy: maxOracleAge != 300");
        require(oracle.maxDeviationBps() == 50, "deploy: maxDeviationBps != 50");
        require(oracle.maxConfidenceBps() == 30, "deploy: maxConfidenceBps != 30");
        oracle.setFeed(usdc, PYTH_USDC_USD);
        oracle.setFeed(eurc, PYTH_EURC_USD);
        oracle.setRedstoneFeed(usdc, REDSTONE_USDC);
        oracle.setRedstoneFeed(eurc, REDSTONE_EURC);

        // 2) Morpho oracle adapters
        MorphoOracleAdapter adapterM1 = new MorphoOracleAdapter(address(oracle), eurc, usdc);
        MorphoOracleAdapter adapterM2 = new MorphoOracleAdapter(address(oracle), usdc, eurc);

        // 3) Market registry
        FxMarketRegistry registry = new FxMarketRegistry(morpho, deployer);

        // 4) Create + register markets M1 (loan=EURC, collat=USDC) + M2 (mirror)
        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irm, lltv: lltv
        });
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irm, lltv: lltv
        });
        bytes32 m1Id = registry.createAndRegisterMarket(m1);
        bytes32 m2Id = registry.createAndRegisterMarket(m2);

        // 5) FxReceipts (ERC-4626 per loan asset)
        MorphoMarketParams memory mpM1 = MorphoMarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irm, lltv: lltv
        });
        MorphoMarketParams memory mpM2 = MorphoMarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irm, lltv: lltv
        });
        FxReceipt fxEURC = new FxReceipt(IERC20(eurc), "fxEURC supply receipt", "fxEURC", morpho, mpM1);
        FxReceipt fxUSDC = new FxReceipt(IERC20(usdc), "fxUSDC supply receipt", "fxUSDC", morpho, mpM2);

        // 6) Liquidator
        FxLiquidator liquidator = new FxLiquidator(morpho, address(registry), address(oracle), deployer);

        // 7) Hub-side CCTP V2 message receiver
        FxHubMessageReceiver receiver = new FxHubMessageReceiver(messageTransmitter, usdc, address(registry));

        // 8) FxTimelock + atomic admin handoff (spec §10.2).
        FxTimelock timelock = _deployTimelockAndHandoff(deployer, oracle, registry, liquidator);

        vm.stopBroadcast();

        _assertHandoff(address(timelock), deployer, oracle, registry, liquidator);

        console2.log("================ deployed ================");
        console2.log("FxOracle              ", address(oracle));
        console2.log("MorphoOracleAdapter M1", address(adapterM1));
        console2.log("MorphoOracleAdapter M2", address(adapterM2));
        console2.log("FxMarketRegistry      ", address(registry));
        console2.log("FxReceipt fxEURC      ", address(fxEURC));
        console2.log("FxReceipt fxUSDC      ", address(fxUSDC));
        console2.log("FxLiquidator          ", address(liquidator));
        console2.log("FxHubMessageReceiver  ", address(receiver));
        console2.log("FxTimelock            ", address(timelock));
        console2.log("Market M1 id (EURC/USDC):");
        console2.logBytes32(m1Id);
        console2.log("Market M2 id (USDC/EURC):");
        console2.logBytes32(m2Id);

        console2.log("==========================================");
        console2.log("Next steps:");
        console2.log("  1. Save deployer USDC for future tx gas (faucet again if needed)");
        console2.log("  2. FxTimelock now holds DEFAULT_ADMIN_ROLE on oracle/registry/liquidator");
        console2.log("     Migrate OPERATIONS_ROLE from deployer to a 3-of-5 multisig op-level");
        console2.log("  3. Register all 8 contracts with Circle SCP (bun run sdk:circle:register)");
        console2.log("  4. Deploy FxSpoke on Ethereum/Base/etc with ARC_HUB_RECEIVER = above");
        console2.log("  5. Smoke-test: USDC supply -> withdraw round-trip via Tenderly TestNet");
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
        require(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), timelock),         "handoff: oracle admin != timelock");
        require(!oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), deployer),        "handoff: deployer still oracle admin");
        require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), timelock),     "handoff: registry admin != timelock");
        require(!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer),    "handoff: deployer still registry admin");
        require(liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), timelock), "handoff: liq admin != timelock");
        require(!liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer),"handoff: deployer still liq admin");
    }
}
