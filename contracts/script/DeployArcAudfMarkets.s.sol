// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice Minimal interface for the LIVE Arc Testnet `FxMarketRegistry`.
///
/// The deployed registry at `0x813232259c9b922e7571F15220617C80581f1464`
/// was built from the same Ownable, deployer-owned source as the Fuji
/// hub registry. `createAndRegisterMarket(MarketParams)` is the canonical
/// add-market path; caller must be `owner()`.
interface ILegacyFxMarketRegistry {
    function createAndRegisterMarket(IFxMarketRegistry.MarketParams calldata p)
        external
        returns (bytes32 marketId);
    function MORPHO() external view returns (address);
    function owner() external view returns (address);
}

/// @notice Add AUDF-collateralized Morpho markets to the live Arc hub.
///
/// New markets (M3 + M4) — does NOT touch M1 / M2 (the existing EURC/USDC
/// pair from the original Arc deploy):
///   * M3: loan = AUDF, collateral = USDC  (borrowers post USDC, borrow AUDF)
///   * M4: loan = USDC, collateral = AUDF  (borrowers post AUDF, borrow USDC)
///
/// Side effects:
///   1. Deploys a FRESH FxOracle wired for USDC + AUDF. The original
///      Arc FxOracle is only configured for USDC + EURC and is owned by
///      FxTimelock — we don't retrofit it; same pattern as the Fuji MXNB
///      add-market path.
///   2. Deploys two MorphoOracleAdapter instances (M3 and M4).
///   3. Calls `createAndRegisterMarket` twice on the EXISTING
///      `FxMarketRegistry` from `deployments/arc-testnet.json`.
///      Caller must equal `owner()`.
///   4. Optionally deploys FxReceipt wrappers — gated by DEPLOY_RECEIPTS=true.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY        — funded on Arc; MUST equal the live
///                                 FxMarketRegistry.owner().
///
/// Optional env (sensible Arc defaults):
///   ARC_REGISTRY                default 0x813232259c9b922e7571F15220617C80581f1464
///   ARC_PYTH                    default 0x2880aB155794e7179c9eE2e38200202908C17B43
///   ARC_USDC                    default 0x3600000000000000000000000000000000000000 (6-dec ERC-20)
///   ARC_AUDF                    default 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b
///   ARC_IRM                     default 0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1 (IrmMock)
///   FX_HUB_LLTV                 default 860000000000000000 (0.86e18)
///   FX_ORACLE_MAX_AGE_S         default 300
///   FX_ORACLE_MAX_DEV_BPS       default 50
///   FX_ORACLE_MAX_CONF_BPS      default 30
///   PYTH_USDC_USD               default 0xeaa0…495617 (canonical Pyth USDC/USD)
///   PYTH_AUD_USD                default 0x67a6…854a80 (canonical Pyth AUD/USD)
///   PYTH_AUD_USD_INVERTED       default false — Pyth reports AUD/USD
///                               (1 AUD ≈ 0.66 USD); we want USD per AUDF,
///                               which AUD/USD already gives directly.
///                               Set true ONLY if you supply a USD/AUD feed.
///   DEPLOY_RECEIPTS             default false — set true to also mint
///                               fxAUDF + fxUSDC4 supply receipts for M3/M4.
contract DeployArcAudfMarkets is Script {
    /*//////////////////////////////////////////////////////////////
                                DEFAULTS
    //////////////////////////////////////////////////////////////*/

    address constant DEFAULT_REGISTRY = 0x813232259c9b922e7571F15220617C80581f1464;
    address constant DEFAULT_PYTH     = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address constant DEFAULT_USDC     = 0x3600000000000000000000000000000000000000;
    address constant DEFAULT_AUDF     = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address constant DEFAULT_IRM      = 0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1;

    /// USDC/USD on Pyth — same canonical feed as Fuji.
    bytes32 constant DEFAULT_PYTH_USDC_USD =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    /// Pyth's AUD/USD price feed (1 AUD = X USD, ≈ 0.66). Already in the
    /// USD-per-AUD orientation the protocol expects; no inversion needed.
    bytes32 constant DEFAULT_PYTH_AUD_USD =
        0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80;

    /*//////////////////////////////////////////////////////////////
                                RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address registryAddr = vm.envOr("ARC_REGISTRY", DEFAULT_REGISTRY);
        address pyth         = vm.envOr("ARC_PYTH",     DEFAULT_PYTH);
        address usdc         = vm.envOr("ARC_USDC",     DEFAULT_USDC);
        address audf         = vm.envOr("ARC_AUDF",     DEFAULT_AUDF);
        address irmAddr      = vm.envOr("ARC_IRM",      DEFAULT_IRM);
        uint256 lltv         = vm.envOr("FX_HUB_LLTV",   uint256(0.86e18));
        uint256 maxAge       = vm.envOr("FX_ORACLE_MAX_AGE_S",    uint256(300));
        uint256 maxDev       = vm.envOr("FX_ORACLE_MAX_DEV_BPS",  uint256(50));
        uint256 maxConf      = vm.envOr("FX_ORACLE_MAX_CONF_BPS", uint256(30));
        bytes32 feedUsdc     = vm.envOr("PYTH_USDC_USD", DEFAULT_PYTH_USDC_USD);
        bytes32 feedAudUsd   = vm.envOr("PYTH_AUD_USD",  DEFAULT_PYTH_AUD_USD);
        bool audInverted     = vm.envOr("PYTH_AUD_USD_INVERTED", false);
        bool deployReceipts  = vm.envOr("DEPLOY_RECEIPTS", false);

        ILegacyFxMarketRegistry registry = ILegacyFxMarketRegistry(registryAddr);

        // Pre-flight checks (no broadcast yet — read-only).
        address registryOwner = registry.owner();
        require(
            registryOwner == deployer,
            "DeployArcAudfMarkets: deployer is not the live FxMarketRegistry owner"
        );
        address morphoAddr = registry.MORPHO();
        require(morphoAddr != address(0), "DeployArcAudfMarkets: registry has zero MORPHO");

        console2.log("deployer            ", deployer);
        console2.log("FxMarketRegistry    ", registryAddr);
        console2.log("MorphoBlue (via reg)", morphoAddr);
        console2.log("IRM                 ", irmAddr);
        console2.log("Pyth                ", pyth);
        console2.log("USDC                ", usdc);
        console2.log("AUDF                ", audf);
        console2.log("LLTV                ", lltv);
        console2.log("Pyth USDC/USD       ", uint256(feedUsdc));
        console2.log("Pyth AUD/USD feed   ", uint256(feedAudUsd));
        console2.log("AUD feed inverted   ", audInverted);
        console2.log("deployReceipts      ", deployReceipts);

        vm.startBroadcast(pk);

        // 1) Fresh FxOracle wired for USDC + AUDF.
        FxOracle oracle = new FxOracle(pyth, deployer, maxAge, maxDev, maxConf);
        require(oracle.maxOracleAge()     == maxAge,  "maxOracleAge mismatch");
        require(oracle.maxDeviationBps()  == maxDev,  "maxDeviationBps mismatch");
        require(oracle.maxConfidenceBps() == maxConf, "maxConfidenceBps mismatch");

        // USDC/USD — not inverted.
        oracle.setFeed(usdc, feedUsdc);
        // AUD/USD — not inverted (Pyth quotes USD per AUD directly).
        oracle.setPythFeedConfig(audf, feedAudUsd, audInverted);

        // 2) MorphoOracleAdapters (one per market direction).
        MorphoOracleAdapter adapterM3 = new MorphoOracleAdapter(address(oracle), audf, usdc);
        MorphoOracleAdapter adapterM4 = new MorphoOracleAdapter(address(oracle), usdc, audf);

        // 3) Register markets on the LIVE registry.
        IFxMarketRegistry.MarketParams memory m3 = IFxMarketRegistry.MarketParams({
            loanToken:       audf,
            collateralToken: usdc,
            oracle:          address(adapterM3),
            irm:             irmAddr,
            lltv:            lltv
        });
        IFxMarketRegistry.MarketParams memory m4 = IFxMarketRegistry.MarketParams({
            loanToken:       usdc,
            collateralToken: audf,
            oracle:          address(adapterM4),
            irm:             irmAddr,
            lltv:            lltv
        });
        bytes32 m3Id = registry.createAndRegisterMarket(m3);
        bytes32 m4Id = registry.createAndRegisterMarket(m4);

        // 4) Optional FxReceipt wrappers.
        address fxAUDF;
        address fxUSDC4;
        if (deployReceipts) {
            MorphoMarketParams memory mpM3 = MorphoMarketParams({
                loanToken:       audf,
                collateralToken: usdc,
                oracle:          address(adapterM3),
                irm:             irmAddr,
                lltv:            lltv
            });
            MorphoMarketParams memory mpM4 = MorphoMarketParams({
                loanToken:       usdc,
                collateralToken: audf,
                oracle:          address(adapterM4),
                irm:             irmAddr,
                lltv:            lltv
            });
            fxAUDF  = address(new FxReceipt(IERC20(audf), "fxAUDF supply receipt (Arc)", "fxAUDF",  morphoAddr, mpM3));
            fxUSDC4 = address(new FxReceipt(IERC20(usdc), "fxUSDC4 supply receipt (Arc)", "fxUSDC4", morphoAddr, mpM4));
        }

        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("fx-Telarana Arc AUDF markets deployment");
        console2.log("============================================");
        console2.log("FxOracle (USDC+AUDF)  ", address(oracle));
        console2.log("MorphoOracleAdapter M3", address(adapterM3));
        console2.log("MorphoOracleAdapter M4", address(adapterM4));
        console2.log("M3 (loan=AUDF, coll=USDC) id  ", uint256(m3Id));
        console2.log("M4 (loan=USDC, coll=AUDF) id  ", uint256(m4Id));
        if (deployReceipts) {
            console2.log("FxReceipt fxAUDF      ", fxAUDF);
            console2.log("FxReceipt fxUSDC4     ", fxUSDC4);
        }
    }
}
