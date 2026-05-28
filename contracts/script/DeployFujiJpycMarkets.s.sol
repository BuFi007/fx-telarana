// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice Minimal interface for the LIVE Fuji `FxMarketRegistry` (Ownable).
interface ILegacyFxMarketRegistry {
    function createAndRegisterMarket(IFxMarketRegistry.MarketParams calldata p)
        external
        returns (bytes32 marketId);
    function MORPHO() external view returns (address);
    function owner() external view returns (address);
}

/// @notice Add JPYC-collateralized Morpho markets to the live Fuji hub.
///
/// New markets (M5 + M6) -- does NOT touch M1-M4 from previous deploys:
///   * M5: loan = JPYC, collateral = USDC  (borrowers post USDC, borrow JPYC)
///   * M6: loan = USDC, collateral = JPYC  (borrowers post JPYC, borrow USDC)
///
/// Side effects:
///   1. Deploys a FRESH FxOracle wired for USDC + JPYC (current
///      AccessControl source; separate from the original FxOracle and
///      the MXNB FxOracle).
///   2. Deploys two MorphoOracleAdapter instances (M5 and M6).
///   3. Calls `createAndRegisterMarket` twice on the EXISTING
///      `FxMarketRegistry` from `deployments/avalanche-fuji.json`.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///
/// Optional env (sensible Fuji defaults):
///   FUJI_REGISTRY, FUJI_PYTH, FUJI_USDC, FUJI_JPYC, FUJI_IRM
///   FX_HUB_LLTV, FX_ORACLE_MAX_AGE_S, FX_ORACLE_MAX_DEV_BPS,
///   FX_ORACLE_MAX_CONF_BPS, PYTH_USDC_USD, PYTH_JPY_USD
contract DeployFujiJpycMarkets is Script {
    address constant DEFAULT_REGISTRY = 0x7ba745b979e027992ECFa51207666e3F5B46cF0a;
    address constant DEFAULT_PYTH     = 0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509;
    address constant DEFAULT_USDC     = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address constant DEFAULT_JPYC     = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;
    address constant DEFAULT_IRM      = 0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA;

    /// USDC/USD on Pyth -- same as all other Fuji deploys.
    bytes32 constant DEFAULT_PYTH_USDC_USD =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    /// Pyth JPY/USD feed. Pyth reports JPY per USD (~ 140); we invert so
    /// the protocol reads USD per JPYC (~ 0.007).
    bytes32 constant DEFAULT_PYTH_JPY_USD =
        0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address registryAddr = vm.envOr("FUJI_REGISTRY", DEFAULT_REGISTRY);
        address pyth         = vm.envOr("FUJI_PYTH",     DEFAULT_PYTH);
        address usdc         = vm.envOr("FUJI_USDC",     DEFAULT_USDC);
        address jpyc         = vm.envOr("FUJI_JPYC",     DEFAULT_JPYC);
        address irmAddr      = vm.envOr("FUJI_IRM",      DEFAULT_IRM);
        uint256 lltv         = vm.envOr("FX_HUB_LLTV",   uint256(0.86e18));
        uint256 maxAge       = vm.envOr("FX_ORACLE_MAX_AGE_S",    uint256(300));
        uint256 maxDev       = vm.envOr("FX_ORACLE_MAX_DEV_BPS",  uint256(50));
        uint256 maxConf      = vm.envOr("FX_ORACLE_MAX_CONF_BPS", uint256(30));
        bytes32 feedUsdc     = vm.envOr("PYTH_USDC_USD", DEFAULT_PYTH_USDC_USD);
        bytes32 feedJpyUsd   = vm.envOr("PYTH_JPY_USD",  DEFAULT_PYTH_JPY_USD);

        ILegacyFxMarketRegistry registry = ILegacyFxMarketRegistry(registryAddr);

        // Pre-flight
        address registryOwner = registry.owner();
        require(registryOwner == deployer, "deployer is not the live FxMarketRegistry owner");
        address morphoAddr = registry.MORPHO();
        require(morphoAddr != address(0), "registry has zero MORPHO");

        console2.log("deployer            ", deployer);
        console2.log("FxMarketRegistry    ", registryAddr);
        console2.log("MorphoBlue (via reg)", morphoAddr);
        console2.log("IRM                 ", irmAddr);
        console2.log("Pyth                ", pyth);
        console2.log("USDC                ", usdc);
        console2.log("JPYC                ", jpyc);
        console2.log("LLTV                ", lltv);

        vm.startBroadcast(pk);

        // 1) Fresh FxOracle wired for USDC + JPYC
        FxOracle oracle = new FxOracle(pyth, deployer, maxAge, maxDev, maxConf);
        require(oracle.maxOracleAge()     == maxAge,  "maxOracleAge mismatch");
        require(oracle.maxDeviationBps()  == maxDev,  "maxDeviationBps mismatch");
        require(oracle.maxConfidenceBps() == maxConf, "maxConfidenceBps mismatch");

        // USDC/USD -- not inverted.
        oracle.setFeed(usdc, feedUsdc);
        // JPY/USD -- inverted so the protocol reads USD-per-JPYC (~ 0.007).
        oracle.setPythFeedConfig(jpyc, feedJpyUsd, true);

        // 2) MorphoOracleAdapters (one per market direction).
        MorphoOracleAdapter adapterM5 = new MorphoOracleAdapter(address(oracle), jpyc, usdc);
        MorphoOracleAdapter adapterM6 = new MorphoOracleAdapter(address(oracle), usdc, jpyc);

        // 3) Register markets on the LIVE registry.
        IFxMarketRegistry.MarketParams memory m5 = IFxMarketRegistry.MarketParams({
            loanToken:       jpyc,
            collateralToken: usdc,
            oracle:          address(adapterM5),
            irm:             irmAddr,
            lltv:            lltv
        });
        IFxMarketRegistry.MarketParams memory m6 = IFxMarketRegistry.MarketParams({
            loanToken:       usdc,
            collateralToken: jpyc,
            oracle:          address(adapterM6),
            irm:             irmAddr,
            lltv:            lltv
        });
        bytes32 m5Id = registry.createAndRegisterMarket(m5);
        bytes32 m6Id = registry.createAndRegisterMarket(m6);

        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("fx-Telarana Fuji JPYC markets deployment");
        console2.log("============================================");
        console2.log("FxOracle (USDC+JPYC)  ", address(oracle));
        console2.log("MorphoOracleAdapter M5", address(adapterM5));
        console2.log("MorphoOracleAdapter M6", address(adapterM6));
        console2.log("M5 (loan=JPYC, coll=USDC) id");
        console2.logBytes32(m5Id);
        console2.log("M6 (loan=USDC, coll=JPYC) id");
        console2.logBytes32(m6Id);
    }
}
