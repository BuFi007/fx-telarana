// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice Minimal interface for the LIVE Fuji `FxMarketRegistry`.
///
/// The deployed registry at `0x7ba745b979e027992ECFa51207666e3F5B46cF0a`
/// was built from an older (Ownable, deployer-owned) source — the current
/// in-repo `FxMarketRegistry.sol` is AccessControl-based. We DO NOT
/// touch the live registry's source; we just need its
/// `createAndRegisterMarket(MarketParams)` selector, which matched both
/// past and present revisions. Calling from the deployer (the `owner` of
/// the live Ownable variant) is the canonical add-market path.
interface ILegacyFxMarketRegistry {
    function createAndRegisterMarket(IFxMarketRegistry.MarketParams calldata p)
        external
        returns (bytes32 marketId);
    function MORPHO() external view returns (address);
    function owner() external view returns (address);
}

/// @notice Add MXNB-collateralized Morpho markets to the live Fuji hub.
///
/// New markets (M3 + M4) — does NOT touch M1 / M2 from the original deploy:
///   * M3: loan = MXNB, collateral = USDC  (borrowers post USDC, borrow MXNB)
///   * M4: loan = USDC, collateral = MXNB  (borrowers post MXNB, borrow USDC)
///
/// Side effects:
///   1. Deploys a FRESH FxOracle wired for USDC + MXNB (current
///      AccessControl source; the live FxOracle at 0xf7fcdca3… is
///      configured only for USDC + EURC, and live state is owned by
///      FxTimelock — we don't try to retrofit it).
///   2. Deploys two MorphoOracleAdapter instances (M3 and M4).
///   3. Calls `createAndRegisterMarket` twice on the EXISTING
///      `FxMarketRegistry` from `deployments/avalanche-fuji.json`.
///      Caller must be the registry's current `owner()`.
///   4. Optionally deploys FxReceipt wrappers (fxMXNB + a parallel
///      fxUSDC pointing at M4) — gated by DEPLOY_RECEIPTS=true.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY        — funded on Fuji; MUST equal the live
///                                 FxMarketRegistry.owner().
///
/// Optional env (sensible Fuji defaults):
///   FUJI_REGISTRY               default 0x7ba745b979e027992ECFa51207666e3F5B46cF0a
///   FUJI_PYTH                   default 0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509
///   FUJI_USDC                   default 0x5425890298aed601595a70AB815c96711a31Bc65
///   FUJI_MXNB                   default 0xAB99d44185af87AeB08361588F00F59B0CE85eBb
///   FUJI_IRM                    default 0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA (IrmMock)
///   FX_HUB_LLTV                 default 860000000000000000 (0.86e18)
///   FX_ORACLE_MAX_AGE_S         default 300
///   FX_ORACLE_MAX_DEV_BPS       default 50
///   FX_ORACLE_MAX_CONF_BPS      default 30
///   PYTH_USDC_USD               default 0xeaa0…495617 (canonical Pyth USDC/USD)
///   PYTH_USD_MXN                default 0xe13b…b77ca (canonical Pyth USD/MXN)
///   PYTH_USD_MXN_INVERTED       default true — Pyth reports USD/MXN
///                               (MXN per USD ≈ 17). We need USD per MXNB
///                               (≈ 0.058). Set false ONLY if you supply
///                               a feed that already quotes USD/MXNB.
///   DEPLOY_RECEIPTS             default false — set true to also mint
///                               fxMXNB + fxUSDC supply receipts for M3/M4.
contract DeployFujiMxnbMarkets is Script {
    /*//////////////////////////////////////////////////////////////
                                DEFAULTS
    //////////////////////////////////////////////////////////////*/

    address constant DEFAULT_REGISTRY = 0x7ba745b979e027992ECFa51207666e3F5B46cF0a;
    address constant DEFAULT_PYTH     = 0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509;
    address constant DEFAULT_USDC     = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address constant DEFAULT_MXNB     = 0xAB99d44185af87AeB08361588F00F59B0CE85eBb;
    address constant DEFAULT_IRM      = 0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA;

    /// USDC/USD on Pyth — same as the original Fuji deploy.
    bytes32 constant DEFAULT_PYTH_USDC_USD =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    /// Pyth's MXN price feed. Canonical Pyth feed name in their catalog
    /// is "USD/MXN" (1 USD = X MXN ≈ 17). We invert for the protocol's
    /// USD-denominated convention; the deploy operator should verify
    /// against pyth.network/price-feeds before broadcasting.
    bytes32 constant DEFAULT_PYTH_USD_MXN =
        0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;

    /*//////////////////////////////////////////////////////////////
                                RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address registryAddr = vm.envOr("FUJI_REGISTRY", DEFAULT_REGISTRY);
        address pyth         = vm.envOr("FUJI_PYTH",     DEFAULT_PYTH);
        address usdc         = vm.envOr("FUJI_USDC",     DEFAULT_USDC);
        address mxnb         = vm.envOr("FUJI_MXNB",     DEFAULT_MXNB);
        address irmAddr      = vm.envOr("FUJI_IRM",      DEFAULT_IRM);
        uint256 lltv         = vm.envOr("FX_HUB_LLTV",   uint256(0.86e18));
        uint256 maxAge       = vm.envOr("FX_ORACLE_MAX_AGE_S",    uint256(300));
        uint256 maxDev       = vm.envOr("FX_ORACLE_MAX_DEV_BPS",  uint256(50));
        uint256 maxConf      = vm.envOr("FX_ORACLE_MAX_CONF_BPS", uint256(30));
        bytes32 feedUsdc     = vm.envOr("PYTH_USDC_USD", DEFAULT_PYTH_USDC_USD);
        bytes32 feedUsdMxn   = vm.envOr("PYTH_USD_MXN",  DEFAULT_PYTH_USD_MXN);
        bool mxnInverted     = vm.envOr("PYTH_USD_MXN_INVERTED", true);
        bool deployReceipts  = vm.envOr("DEPLOY_RECEIPTS", false);

        ILegacyFxMarketRegistry registry = ILegacyFxMarketRegistry(registryAddr);

        // Pre-flight checks (no broadcast yet — read-only).
        address registryOwner = registry.owner();
        require(
            registryOwner == deployer,
            "DeployFujiMxnbMarkets: deployer is not the live FxMarketRegistry owner"
        );
        address morphoAddr = registry.MORPHO();
        require(morphoAddr != address(0), "DeployFujiMxnbMarkets: registry has zero MORPHO");

        console2.log("deployer            ", deployer);
        console2.log("FxMarketRegistry    ", registryAddr);
        console2.log("MorphoBlue (via reg)", morphoAddr);
        console2.log("IRM                 ", irmAddr);
        console2.log("Pyth                ", pyth);
        console2.log("USDC                ", usdc);
        console2.log("MXNB                ", mxnb);
        console2.log("LLTV                ", lltv);
        console2.log("Pyth USDC/USD       ", uint256(feedUsdc));
        console2.log("Pyth USD/MXN feed   ", uint256(feedUsdMxn));
        console2.log("MXN feed inverted   ", mxnInverted);
        console2.log("deployReceipts      ", deployReceipts);

        vm.startBroadcast(pk);

        // 1) Fresh FxOracle wired for USDC + MXNB. Current AccessControl
        //    source; admin role goes to the deployer for bootstrap. After
        //    smoke + audit on the new markets, ops can hand DEFAULT_ADMIN_ROLE
        //    off to the existing FxTimelock with the same atomic-handoff
        //    pattern documented in DeployAvalancheFuji.s.sol.
        FxOracle oracle = new FxOracle(pyth, deployer, maxAge, maxDev, maxConf);
        require(oracle.maxOracleAge()     == maxAge,  "maxOracleAge mismatch");
        require(oracle.maxDeviationBps()  == maxDev,  "maxDeviationBps mismatch");
        require(oracle.maxConfidenceBps() == maxConf, "maxConfidenceBps mismatch");

        // USDC/USD — not inverted.
        oracle.setFeed(usdc, feedUsdc);
        // USD/MXN — inverted so the protocol reads USD-per-MXNB.
        oracle.setPythFeedConfig(mxnb, feedUsdMxn, mxnInverted);

        // 2) MorphoOracleAdapters (one per market direction).
        //    Adapter takes (fxOracle, loanToken, collateralToken).
        MorphoOracleAdapter adapterM3 = new MorphoOracleAdapter(address(oracle), mxnb, usdc);
        MorphoOracleAdapter adapterM4 = new MorphoOracleAdapter(address(oracle), usdc, mxnb);

        // 3) Register markets on the LIVE registry. Deployer must equal
        //    registry.owner(); pre-flight check above guarantees that.
        IFxMarketRegistry.MarketParams memory m3 = IFxMarketRegistry.MarketParams({
            loanToken:       mxnb,
            collateralToken: usdc,
            oracle:          address(adapterM3),
            irm:             irmAddr,
            lltv:            lltv
        });
        IFxMarketRegistry.MarketParams memory m4 = IFxMarketRegistry.MarketParams({
            loanToken:       usdc,
            collateralToken: mxnb,
            oracle:          address(adapterM4),
            irm:             irmAddr,
            lltv:            lltv
        });
        bytes32 m3Id = registry.createAndRegisterMarket(m3);
        bytes32 m4Id = registry.createAndRegisterMarket(m4);

        // 4) Optional FxReceipt wrappers. Off by default — ops can
        //    iterate on the wrappers without re-deploying the markets.
        address fxMXNB;
        address fxUSDC4;
        if (deployReceipts) {
            MorphoMarketParams memory mpM3 = MorphoMarketParams({
                loanToken:       mxnb,
                collateralToken: usdc,
                oracle:          address(adapterM3),
                irm:             irmAddr,
                lltv:            lltv
            });
            MorphoMarketParams memory mpM4 = MorphoMarketParams({
                loanToken:       usdc,
                collateralToken: mxnb,
                oracle:          address(adapterM4),
                irm:             irmAddr,
                lltv:            lltv
            });
            fxMXNB  = address(new FxReceipt(IERC20(mxnb), "fxMXNB supply receipt (Fuji)", "fxMXNB",  morphoAddr, mpM3));
            fxUSDC4 = address(new FxReceipt(IERC20(usdc), "fxUSDC4 supply receipt (Fuji)", "fxUSDC4", morphoAddr, mpM4));
        }

        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("fx-Telarana Fuji MXNB markets deployment");
        console2.log("============================================");
        console2.log("FxOracle (USDC+MXNB)  ", address(oracle));
        console2.log("MorphoOracleAdapter M3", address(adapterM3));
        console2.log("MorphoOracleAdapter M4", address(adapterM4));
        console2.log("M3 (loan=MXNB, coll=USDC) id  ", uint256(m3Id));
        console2.log("M4 (loan=USDC, coll=MXNB) id  ", uint256(m4Id));
        if (deployReceipts) {
            console2.log("FxReceipt fxMXNB      ", fxMXNB);
            console2.log("FxReceipt fxUSDC4     ", fxUSDC4);
        }
    }
}
