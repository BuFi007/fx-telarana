// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";

/// @notice Deploys the sprint-1 FxOracle required by the perps stack.
///         This is intentionally separate from the historical hub deploy
///         scripts so the perps broadcast can refuse stale pre-sprint-1
///         oracles while still giving ops a one-command way to create the
///         correct oracle first.
contract DeployPerpOracle is Script {
    uint256 internal constant FUJI_CHAIN_ID = 43_113;
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant FUJI_PYTH = 0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509;
    address internal constant FUJI_USDC = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address internal constant FUJI_EURC = 0x5E44db7996c682E92a960b65AC713a54AD815c6B;
    address internal constant FUJI_MXNB = 0xAB99d44185af87AeB08361588F00F59B0CE85eBb;

    address internal constant ARC_PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARC_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant ARC_TJPYC = 0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a;
    address internal constant ARC_TMXNB = 0xe8F76f90553F50E76731afbeF1ac83a9152fFBEb;
    address internal constant ARC_TCHFC = 0x249DBFd4ac17247Cf10098F6C3937F90570b5750;
    address internal constant ARC_CIRBTC = 0x44cEe9E472C34b2f0d9710CD8aBd02dadb912761;

    bytes32 internal constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 internal constant PYTH_EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;
    bytes32 internal constant PYTH_USD_JPY = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 internal constant PYTH_USD_MXN = 0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;
    bytes32 internal constant PYTH_USD_CHF = 0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    bytes32 internal constant REDSTONE_USDC = "USDC";
    bytes32 internal constant REDSTONE_EURC = "EURC";
    bytes32 internal constant REDSTONE_JPY = "JPY";
    bytes32 internal constant REDSTONE_MXN = "MXN";
    bytes32 internal constant REDSTONE_CHF = "CHF";
    bytes32 internal constant REDSTONE_BTC = "BTC";

    uint256 internal constant MAX_ORACLE_AGE_HARD_CAP = 30 minutes;
    uint256 internal constant MAX_DEVIATION_BPS_HARD_CAP = 500;
    uint256 internal constant MAX_CONFIDENCE_BPS_HARD_CAP = 500;

    error UnsupportedChain(uint256 chainId);
    error BootstrapAdminMustBeDeployer(address deployer, address oracleInitialAdmin);
    error OracleHardCapMismatch(string selectorName, uint256 actual, uint256 expected);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address oracleInitialAdmin = vm.envOr("ORACLE_INITIAL_ADMIN", deployer);
        if (oracleInitialAdmin != deployer) revert BootstrapAdminMustBeDeployer(deployer, oracleInitialAdmin);

        uint256 maxAge = vm.envOr("FX_ORACLE_MAX_AGE_S", uint256(300));
        uint256 maxDev = vm.envOr("FX_ORACLE_MAX_DEV_BPS", uint256(50));
        uint256 maxConf = vm.envOr("FX_ORACLE_MAX_CONF_BPS", uint256(30));
        string memory path = vm.envOr(
            "PERP_ORACLE_DEPLOYMENT_PATH",
            string.concat("../deployments/perp-oracle-", vm.toString(block.chainid), ".json")
        );

        address pyth = _pythForChain();

        console2.log("============================================");
        console2.log("Deploying sprint-1 FxOracle for perps");
        console2.log("============================================");
        console2.log("chainId       ", block.chainid);
        console2.log("deployer      ", deployer);
        console2.log("pyth          ", pyth);
        console2.log("maxAge        ", maxAge);
        console2.log("maxDevBps     ", maxDev);
        console2.log("maxConfBps    ", maxConf);

        vm.startBroadcast(pk);
        FxOracle oracle = new FxOracle(pyth, deployer, maxAge, maxDev, maxConf);
        _configureFeeds(oracle);
        vm.stopBroadcast();

        _verifyHardCaps(oracle);
        _writeManifest(path, deployer, pyth, address(oracle), maxAge, maxDev, maxConf);

        console2.log("FxOracle      ", address(oracle));
        console2.log("manifest      ", path);
    }

    function _pythForChain() internal view returns (address) {
        if (block.chainid == FUJI_CHAIN_ID) return vm.envOr("FUJI_PYTH", FUJI_PYTH);
        if (block.chainid == ARC_CHAIN_ID) return vm.envOr("ARC_PYTH", ARC_PYTH);
        revert UnsupportedChain(block.chainid);
    }

    function _configureFeeds(FxOracle oracle) internal {
        if (block.chainid == FUJI_CHAIN_ID) {
            address usdc = vm.envOr("FUJI_USDC", FUJI_USDC);
            address eurc = vm.envOr("FUJI_EURC", FUJI_EURC);
            address mxnb = vm.envOr("FUJI_MXNB", FUJI_MXNB);
            _setFeed(oracle, usdc, PYTH_USDC_USD, false, REDSTONE_USDC);
            _setFeed(oracle, eurc, PYTH_EURC_USD, false, REDSTONE_EURC);
            _setFeed(oracle, mxnb, PYTH_USD_MXN, true, REDSTONE_MXN);
            return;
        }

        if (block.chainid == ARC_CHAIN_ID) {
            address usdc = vm.envOr("ARC_USDC", ARC_USDC);
            address eurc = vm.envOr("ARC_EURC", ARC_EURC);
            address tjpyc = vm.envOr("ARC_TJPYC", ARC_TJPYC);
            address tmxnb = vm.envOr("ARC_TMXNB", ARC_TMXNB);
            address tchfc = vm.envOr("ARC_TCHFC", ARC_TCHFC);
            address cirbtc = vm.envOr("ARC_CIRBTC", ARC_CIRBTC);
            _setFeed(oracle, usdc, PYTH_USDC_USD, false, REDSTONE_USDC);
            _setFeed(oracle, eurc, PYTH_EURC_USD, false, REDSTONE_EURC);
            _setFeed(oracle, tjpyc, PYTH_USD_JPY, true, REDSTONE_JPY);
            _setFeed(oracle, tmxnb, PYTH_USD_MXN, true, REDSTONE_MXN);
            _setFeed(oracle, tchfc, PYTH_USD_CHF, true, REDSTONE_CHF);
            _setFeed(oracle, cirbtc, PYTH_BTC_USD, false, REDSTONE_BTC);
            return;
        }

        revert UnsupportedChain(block.chainid);
    }

    function _setFeed(FxOracle oracle, address token, bytes32 pythFeed, bool inverted, bytes32 redstoneFeed) internal {
        oracle.setPythFeedConfig(token, pythFeed, inverted);
        oracle.setRedstoneFeed(token, redstoneFeed);
    }

    function _verifyHardCaps(FxOracle oracle) internal view {
        if (oracle.MAX_ORACLE_AGE_HARD_CAP() != MAX_ORACLE_AGE_HARD_CAP) {
            revert OracleHardCapMismatch(
                "MAX_ORACLE_AGE_HARD_CAP", oracle.MAX_ORACLE_AGE_HARD_CAP(), MAX_ORACLE_AGE_HARD_CAP
            );
        }
        if (oracle.MAX_DEVIATION_BPS_HARD_CAP() != MAX_DEVIATION_BPS_HARD_CAP) {
            revert OracleHardCapMismatch(
                "MAX_DEVIATION_BPS_HARD_CAP", oracle.MAX_DEVIATION_BPS_HARD_CAP(), MAX_DEVIATION_BPS_HARD_CAP
            );
        }
        if (oracle.MAX_CONFIDENCE_BPS_HARD_CAP() != MAX_CONFIDENCE_BPS_HARD_CAP) {
            revert OracleHardCapMismatch(
                "MAX_CONFIDENCE_BPS_HARD_CAP", oracle.MAX_CONFIDENCE_BPS_HARD_CAP(), MAX_CONFIDENCE_BPS_HARD_CAP
            );
        }
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address pyth,
        address oracle,
        uint256 maxAge,
        uint256 maxDev,
        uint256 maxConf
    ) internal {
        string memory root = "perp-oracle";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "pyth", pyth);
        vm.serializeAddress(root, "FxOracle", oracle);
        vm.serializeUint(root, "maxOracleAge", maxAge);
        vm.serializeUint(root, "maxDeviationBps", maxDev);
        string memory json = vm.serializeUint(root, "maxConfidenceBps", maxConf);
        vm.writeJson(json, path);
    }
}
