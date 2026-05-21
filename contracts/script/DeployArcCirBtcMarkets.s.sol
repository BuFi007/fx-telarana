// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

interface IArcFxMarketRegistry {
    function createAndRegisterMarket(IFxMarketRegistry.MarketParams calldata p) external returns (bytes32 marketId);
    function MORPHO() external view returns (address);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IERC20MetadataView {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Adds Arc testnet cirBTC/FakeCirBTC markets to an Arc FxMarketRegistry.
///
/// Markets:
///   * CIRBTC-M1: loan = cirBTC, collateral = USDC
///   * CIRBTC-M2: loan = USDC, collateral = cirBTC
///
/// The default registry is the currently live Arc Stage 6 registry, but
/// broadcasting against that legacy self-deployed Morpho stack requires
/// ALLOW_LEGACY_STAGE6_CIRBTC_MARKETS=true. Fresh Morpho Labs-backed Arc hub
/// broadcasts should prefer DeployArcTestnet.s.sol, which registers cirBTC
/// before timelock handoff.
contract DeployArcCirBtcMarkets is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_REGISTRY = 0x813232259c9b922e7571F15220617C80581f1464;
    address internal constant DEFAULT_PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address internal constant DEFAULT_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant DEFAULT_CIRBTC = 0x44cEe9E472C34b2f0d9710CD8aBd02dadb912761;

    address internal constant LIVE_STAGE6_MORPHO = 0x3c9b95C6E7B23f094f066733E7797C8680760830;
    address internal constant LIVE_STAGE6_IRM = 0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1;
    address internal constant MORPHO_LABS_MORPHO = 0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4;
    address internal constant MORPHO_LABS_IRM = 0xBD583cc9807980f9e41f7c8250f594fB6173abE3;

    bytes32 internal constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant REDSTONE_USDC = "USDC";
    bytes32 internal constant REDSTONE_BTC = "BTC";

    error WrongChain(uint256 chainId);
    error MissingCode(string label, address target);
    error DeployerNotRegistryAdmin(address deployer, address registry);
    error UnexpectedTokenMetadata(string label);
    error LegacyStage6RegistryRequiresExplicitAllowlist(address registry);
    error UnsupportedMorpho(address morpho);
    error MorphoIrmNotEnabled(address morpho, address irm);
    error MorphoLltvNotEnabled(address morpho, uint256 lltv);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address registryAddr = vm.envOr("ARC_REGISTRY", DEFAULT_REGISTRY);
        address pyth = vm.envOr("ARC_PYTH", DEFAULT_PYTH);
        address usdc = vm.envOr("ARC_USDC", DEFAULT_USDC);
        address cirbtc = vm.envOr("ARC_CIRBTC", DEFAULT_CIRBTC);
        uint256 lltv = vm.envOr("FX_HUB_LLTV", uint256(0.86e18));
        uint256 maxAge = vm.envOr("FX_ORACLE_MAX_AGE_S", uint256(300));
        uint256 maxDev = vm.envOr("FX_ORACLE_MAX_DEV_BPS", uint256(50));
        uint256 maxConf = vm.envOr("FX_ORACLE_MAX_CONF_BPS", uint256(30));
        bool deployReceipts = vm.envOr("DEPLOY_RECEIPTS", false);
        bool allowLegacyStage6 = vm.envOr("ALLOW_LEGACY_STAGE6_CIRBTC_MARKETS", false);
        string memory defaultManifestPath =
            string.concat("../deployments/arc-cirbtc-markets-", vm.toString(block.chainid), ".json");
        string memory manifestPath = vm.envOr("ARC_CIRBTC_MARKETS_PATH", defaultManifestPath);

        IArcFxMarketRegistry registry = IArcFxMarketRegistry(registryAddr);
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        if (!registry.hasRole(adminRole, deployer)) revert DeployerNotRegistryAdmin(deployer, registryAddr);

        address morpho = registry.MORPHO();
        if (morpho == LIVE_STAGE6_MORPHO && !allowLegacyStage6) {
            revert LegacyStage6RegistryRequiresExplicitAllowlist(registryAddr);
        }
        address irm = vm.envOr("ARC_IRM", _defaultIrmForMorpho(morpho));
        _assertCode("FxMarketRegistry", registryAddr);
        _assertCode("Morpho", morpho);
        _assertCode("IRM", irm);
        _assertCode("USDC", usdc);
        _assertCode("cirBTC", cirbtc);
        _assertCirBtcMetadata(cirbtc);
        _assertMorphoConfig(morpho, irm, lltv);

        console2.log("============================================");
        console2.log("Deploying Arc cirBTC Morpho markets");
        console2.log("============================================");
        console2.log("deployer            ", deployer);
        console2.log("registry            ", registryAddr);
        console2.log("morpho              ", morpho);
        console2.log("irm                 ", irm);
        console2.log("pyth                ", pyth);
        console2.log("usdc                ", usdc);
        console2.log("cirBTC              ", cirbtc);
        console2.log("lltv                ", lltv);
        console2.log("deployReceipts      ", deployReceipts);
        console2.log("allowLegacyStage6   ", allowLegacyStage6);

        vm.startBroadcast(pk);
        FxOracle oracle = new FxOracle(pyth, deployer, maxAge, maxDev, maxConf);
        oracle.setPythFeedConfig(usdc, PYTH_USDC_USD, false);
        oracle.setRedstoneFeed(usdc, REDSTONE_USDC);
        oracle.setPythFeedConfig(cirbtc, PYTH_BTC_USD, false);
        oracle.setRedstoneFeed(cirbtc, REDSTONE_BTC);

        MorphoOracleAdapter adapterCirBtcLoan = new MorphoOracleAdapter(address(oracle), cirbtc, usdc);
        MorphoOracleAdapter adapterUsdcLoan = new MorphoOracleAdapter(address(oracle), usdc, cirbtc);

        IFxMarketRegistry.MarketParams memory cirBtcLoan = IFxMarketRegistry.MarketParams({
            loanToken: cirbtc, collateralToken: usdc, oracle: address(adapterCirBtcLoan), irm: irm, lltv: lltv
        });
        IFxMarketRegistry.MarketParams memory usdcLoan = IFxMarketRegistry.MarketParams({
            loanToken: usdc, collateralToken: cirbtc, oracle: address(adapterUsdcLoan), irm: irm, lltv: lltv
        });

        bytes32 cirBtcLoanId = registry.createAndRegisterMarket(cirBtcLoan);
        bytes32 usdcLoanId = registry.createAndRegisterMarket(usdcLoan);

        address fxCirBtc;
        address fxUsdcCirBtc;
        if (deployReceipts) {
            fxCirBtc = address(
                new FxReceipt(
                    IERC20(cirbtc), "fxcirBTC supply receipt (Arc)", "fxcirBTC", morpho, _toMorpho(cirBtcLoan)
                )
            );
            fxUsdcCirBtc = address(
                new FxReceipt(
                    IERC20(usdc), "fxUSDC-cirBTC supply receipt (Arc)", "fxUSDC-cirBTC", morpho, _toMorpho(usdcLoan)
                )
            );
        }
        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("FxOracle              ", address(oracle));
        console2.log("Adapter cirBTC loan   ", address(adapterCirBtcLoan));
        console2.log("Adapter USDC loan     ", address(adapterUsdcLoan));
        console2.log("CIRBTC-M1 id          ", vm.toString(cirBtcLoanId));
        console2.log("CIRBTC-M2 id          ", vm.toString(usdcLoanId));
        if (deployReceipts) {
            console2.log("FxReceipt fxcirBTC   ", fxCirBtc);
            console2.log("FxReceipt fxUSDC-cBTC", fxUsdcCirBtc);
        }
        _writeManifest(
            manifestPath,
            deployer,
            registryAddr,
            morpho,
            irm,
            pyth,
            usdc,
            cirbtc,
            lltv,
            maxAge,
            maxDev,
            maxConf,
            address(oracle),
            address(adapterCirBtcLoan),
            address(adapterUsdcLoan),
            cirBtcLoanId,
            usdcLoanId,
            fxCirBtc,
            fxUsdcCirBtc,
            deployReceipts
        );
        console2.log("manifest              ", manifestPath);
    }

    function _defaultIrmForMorpho(address morpho) internal pure returns (address) {
        if (morpho == LIVE_STAGE6_MORPHO) return LIVE_STAGE6_IRM;
        if (morpho == MORPHO_LABS_MORPHO) return MORPHO_LABS_IRM;
        revert UnsupportedMorpho(morpho);
    }

    function _assertCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert MissingCode(label, target);
    }

    function _assertCirBtcMetadata(address cirbtc) internal view {
        IERC20MetadataView token = IERC20MetadataView(cirbtc);
        if (keccak256(bytes(token.name())) != keccak256("FakeCirBTC")) revert UnexpectedTokenMetadata("name");
        if (keccak256(bytes(token.symbol())) != keccak256("fCirBTC")) revert UnexpectedTokenMetadata("symbol");
        if (token.decimals() != 18) revert UnexpectedTokenMetadata("decimals");
    }

    function _assertMorphoConfig(address morpho, address irm, uint256 lltv) internal view {
        IMorpho morphoBlue = IMorpho(morpho);
        if (!morphoBlue.isIrmEnabled(irm)) revert MorphoIrmNotEnabled(morpho, irm);
        if (!morphoBlue.isLltvEnabled(lltv)) revert MorphoLltvNotEnabled(morpho, lltv);
    }

    function _toMorpho(IFxMarketRegistry.MarketParams memory p) internal pure returns (MorphoMarketParams memory) {
        return MorphoMarketParams({
            loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv
        });
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address registryAddr,
        address morpho,
        address irm,
        address pyth,
        address usdc,
        address cirbtc,
        uint256 lltv,
        uint256 maxAge,
        uint256 maxDev,
        uint256 maxConf,
        address oracle,
        address adapterCirBtcLoan,
        address adapterUsdcLoan,
        bytes32 cirBtcLoanId,
        bytes32 usdcLoanId,
        address fxCirBtc,
        address fxUsdcCirBtc,
        bool deployReceipts
    ) internal {
        string memory root = "arcCirBtcMarkets";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedBlockNumber", block.number);
        vm.serializeUint(root, "deployedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "FxMarketRegistry", registryAddr);
        vm.serializeAddress(root, "Morpho", morpho);
        vm.serializeAddress(root, "IRM", irm);
        vm.serializeAddress(root, "Pyth", pyth);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeAddress(root, "cirBTC", cirbtc);
        vm.serializeString(root, "cirBTCSource", "Arc testnet FakeCirBTC token treated as Circle Wrapped Bitcoin");
        vm.serializeUint(root, "lltv", lltv);
        vm.serializeUint(root, "oracleMaxAgeSeconds", maxAge);
        vm.serializeUint(root, "oracleMaxDeviationBps", maxDev);
        vm.serializeUint(root, "oracleMaxConfidenceBps", maxConf);
        vm.serializeAddress(root, "FxOracle", oracle);
        vm.serializeString(root, "USDC_pythFeedId", vm.toString(PYTH_USDC_USD));
        vm.serializeString(root, "USDC_redstoneFeedId", "USDC");
        vm.serializeString(root, "cirBTC_pythFeedId", vm.toString(PYTH_BTC_USD));
        vm.serializeString(root, "cirBTC_redstoneFeedId", "BTC");
        vm.serializeAddress(root, "MorphoOracleAdapter_cirBTCLoan", adapterCirBtcLoan);
        vm.serializeAddress(root, "MorphoOracleAdapter_usdcLoan", adapterUsdcLoan);
        vm.serializeString(root, "CIRBTC_M1_marketId", vm.toString(cirBtcLoanId));
        vm.serializeAddress(root, "CIRBTC_M1_loanToken", cirbtc);
        vm.serializeAddress(root, "CIRBTC_M1_collateralToken", usdc);
        vm.serializeString(root, "CIRBTC_M2_marketId", vm.toString(usdcLoanId));
        vm.serializeAddress(root, "CIRBTC_M2_loanToken", usdc);
        vm.serializeAddress(root, "CIRBTC_M2_collateralToken", cirbtc);
        vm.serializeBool(root, "receiptsDeployed", deployReceipts);
        vm.serializeAddress(root, "FxReceipt_fxcirBTC", fxCirBtc);
        string memory json = vm.serializeAddress(root, "FxReceipt_fxUSDC_cirBTC", fxUsdcCirBtc);
        vm.writeJson(json, path);
    }
}
