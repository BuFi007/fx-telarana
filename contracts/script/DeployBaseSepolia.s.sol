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
import {MockEURC} from "../src/test-helpers/MockEURC.sol";

/// @notice fx-Telaraña Phase 0 deploy on **Base Sepolia (84532)**.
///
/// Why Base Sepolia first: Morpho Blue, AdaptiveCurveIrm, and Pyth are all live
/// on Base Sepolia today. Arc testnet's Morpho address isn't yet published, so we
/// validate the full Hub stack against real public infra here. Migrate to Arc the
/// moment Morpho ships there (only env-var changes; contract code unchanged).
///
/// Required env:
///   BASE_SEPOLIA_RPC               — RPC endpoint
///   DEPLOYER_PRIVATE_KEY           — funded with Base Sepolia ETH for gas
///
/// Optional env (override the hard-coded testnet defaults):
///   BASE_SEPOLIA_MORPHO            — defaults to 0xBBBB...EEFFCb
///   BASE_SEPOLIA_ADAPTIVE_IRM      — defaults to 0x4641...22687
///   BASE_SEPOLIA_PYTH              — defaults to 0xA2aa...5729
///   BASE_SEPOLIA_USDC              — defaults to 0x036C...DCF7e
///   BASE_SEPOLIA_EURC              — if unset, deploys MockEURC
///   FX_HUB_LLTV                    — defaults to 860000000000000000 (0.86e18)
contract DeployBaseSepolia is Script {
    // ── Hard-coded Base Sepolia defaults (chainId 84532) ────────────────────
    address constant DEFAULT_MORPHO       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant DEFAULT_ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address constant DEFAULT_PYTH         = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;
    address constant DEFAULT_USDC         = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    // CCTP V2 on Base Sepolia (domain 6)
    address constant DEFAULT_CCTP_MESSAGE_TRANSMITTER = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

    bytes32 constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;

    bytes32 constant REDSTONE_USDC = bytes32("USDC");
    bytes32 constant REDSTONE_EURC = bytes32("EURC");

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address morpho = vm.envOr("BASE_SEPOLIA_MORPHO", DEFAULT_MORPHO);
        address irm    = vm.envOr("BASE_SEPOLIA_ADAPTIVE_IRM", DEFAULT_ADAPTIVE_IRM);
        address pyth   = vm.envOr("BASE_SEPOLIA_PYTH", DEFAULT_PYTH);
        address usdc   = vm.envOr("BASE_SEPOLIA_USDC", DEFAULT_USDC);
        address eurc   = vm.envOr("BASE_SEPOLIA_EURC", address(0));
        uint256 lltv   = vm.envOr("FX_HUB_LLTV", uint256(860000000000000000));

        console2.log("deployer", deployer);
        console2.log("morpho  ", morpho);
        console2.log("irm     ", irm);
        console2.log("pyth    ", pyth);
        console2.log("usdc    ", usdc);

        vm.startBroadcast(pk);

        // 1) MockEURC if no canonical EURC on Base Sepolia
        if (eurc == address(0)) {
            MockEURC mockEurc = new MockEURC();
            eurc = address(mockEurc);
            console2.log("MockEURC", eurc);
        } else {
            console2.log("eurc    ", eurc);
        }

        // 2) FxOracle (Pyth primary + RedStone fallback in getMid; deviation
        //    gate enforced in getMidVerified only).
        //    Spec §8 production defaults: staleness=300s, deviation=50 bps, confidence=30 bps.
        FxOracle oracle = new FxOracle(pyth, deployer, 300, 50, 30);
        require(oracle.maxOracleAge() == 300, "deploy: maxOracleAge != 300");
        require(oracle.maxDeviationBps() == 50, "deploy: maxDeviationBps != 50");
        require(oracle.maxConfidenceBps() == 30, "deploy: maxConfidenceBps != 30");
        oracle.setFeed(usdc, PYTH_USDC_USD);
        oracle.setFeed(eurc, PYTH_EURC_USD);
        oracle.setRedstoneFeed(usdc, REDSTONE_USDC);
        oracle.setRedstoneFeed(eurc, REDSTONE_EURC);

        // 3) Morpho oracle adapters (per market direction)
        MorphoOracleAdapter adapterM1 = new MorphoOracleAdapter(address(oracle), eurc, usdc);
        MorphoOracleAdapter adapterM2 = new MorphoOracleAdapter(address(oracle), usdc, eurc);

        // 4) FxMarketRegistry over real Morpho Blue
        FxMarketRegistry registry = new FxMarketRegistry(morpho, deployer);

        // 5) Markets: M1 (loan=EURC, collat=USDC), M2 (loan=USDC, collat=EURC)
        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irm, lltv: lltv
        });
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irm, lltv: lltv
        });
        bytes32 m1Id = registry.createAndRegisterMarket(m1);
        bytes32 m2Id = registry.createAndRegisterMarket(m2);

        // 6) FxReceipts: ERC-4626 over each supply position
        MorphoMarketParams memory mpM1 = MorphoMarketParams({
            loanToken: eurc, collateralToken: usdc, oracle: address(adapterM1), irm: irm, lltv: lltv
        });
        MorphoMarketParams memory mpM2 = MorphoMarketParams({
            loanToken: usdc, collateralToken: eurc, oracle: address(adapterM2), irm: irm, lltv: lltv
        });
        FxReceipt fxEURC = new FxReceipt(IERC20(eurc), "fxEURC supply receipt", "fxEURC", morpho, mpM1);
        FxReceipt fxUSDC = new FxReceipt(IERC20(usdc), "fxUSDC supply receipt", "fxUSDC", morpho, mpM2);

        // 7) Liquidator
        FxLiquidator liquidator = new FxLiquidator(morpho, address(registry), address(oracle), deployer);

        // 8) Hub-side CCTP V2 message receiver (lets spokes deposit through CCTP hooks)
        address cctpMt = vm.envOr("BASE_SEPOLIA_CCTP_MT", DEFAULT_CCTP_MESSAGE_TRANSMITTER);
        FxHubMessageReceiver hubReceiver =
            new FxHubMessageReceiver(cctpMt, usdc, address(registry));

        // 9) FxTimelock + atomic admin handoff (spec §10.2).
        FxTimelock timelock = _deployTimelockAndHandoff(deployer, oracle, registry, liquidator);

        vm.stopBroadcast();

        _assertHandoff(address(timelock), deployer, oracle, registry, liquidator);

        console2.log("============================================");
        console2.log("fx-Telarana Base Sepolia deployment");
        console2.log("============================================");
        console2.log("FxOracle              ", address(oracle));
        console2.log("MorphoOracleAdapter M1", address(adapterM1));
        console2.log("MorphoOracleAdapter M2", address(adapterM2));
        console2.log("FxMarketRegistry      ", address(registry));
        console2.log("FxReceipt fxEURC      ", address(fxEURC));
        console2.log("FxReceipt fxUSDC      ", address(fxUSDC));
        console2.log("FxLiquidator          ", address(liquidator));
        console2.log("FxHubMessageReceiver  ", address(hubReceiver));
        console2.log("FxTimelock            ", address(timelock));
        console2.log("CctpMessageTransmitter", cctpMt);
        console2.log("EURC token            ", eurc);
        console2.log("Market M1 id (EURC/USDC):");
        console2.logBytes32(m1Id);
        console2.log("Market M2 id (USDC/EURC):");
        console2.logBytes32(m2Id);
    }

    /// @dev Deploys an FxTimelock (24h min-delay, deployer = proposer + executor,
    ///      self-administered) and atomically hands DEFAULT_ADMIN_ROLE on each
    ///      admin contract to it. OPERATIONS_ROLE stays on deployer for hot
    ///      pause; multisig migration is op-level (out of scope here).
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
