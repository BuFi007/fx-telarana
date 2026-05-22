// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";

/// @notice Deploys three Arc Testnet Morpho markets on the CANONICAL Morpho
///         Labs MorphoBlue (0x65f435...) -- bypassing the legacy self-deployed
///         FxMarketRegistry that's locked at the old shadow MorphoBlue.
///
/// Markets (USDC loan against issuer-backed collateral):
///   * USDC / MXNB    -- Bitso MXNB on Arc, 86% LLTV
///   * USDC / QCAD    -- QCAD on Arc, 86% LLTV
///   * USDC / cirBTC  -- Circle Wrapped BTC issuer on Arc, 86% LLTV (note: 86%
///                      is high for BTC; tighten to 0.77e18 if production
///                      ever uses this market for real liquidity)
///
/// Pyth + RedStone feeds for these collateral tokens must already be set on
/// the supplied FxOracle. This script is a market-creation step only; oracle
/// configuration is a separate prerequisite (done via `cast send` earlier).
contract DeployArcCanonicalMorphoMarkets is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_MORPHO = 0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4;
    address internal constant DEFAULT_IRM = 0xBD583cc9807980f9e41f7c8250f594fB6173abE3;
    address internal constant DEFAULT_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant DEFAULT_ORACLE = 0xf9b0356A31BC7125e2eD0DADf8b5957860d42c78;

    address internal constant DEFAULT_MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address internal constant DEFAULT_QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;
    address internal constant DEFAULT_CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;

    uint256 internal constant DEFAULT_LLTV = 0.86e18;

    error WrongChain(uint256 chainId);
    error MissingCode(string label, address target);
    error MorphoIrmNotEnabled(address morpho, address irm);
    error MorphoLltvNotEnabled(address morpho, uint256 lltv);
    error MissingOracleFeed(string label, address token);

    struct MarketSpec {
        string symbol;
        address collateralToken;
    }

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IMorpho morpho = IMorpho(vm.envOr("ARC_MORPHO", DEFAULT_MORPHO));
        address irm = vm.envOr("ARC_IRM", DEFAULT_IRM);
        address oracleAddr = vm.envOr("ARC_FX_ORACLE", DEFAULT_ORACLE);
        address usdc = vm.envOr("ARC_USDC", DEFAULT_USDC);
        uint256 lltv = vm.envOr("ARC_LLTV", DEFAULT_LLTV);

        MarketSpec[3] memory specs;
        specs[0] = MarketSpec({symbol: "MXNB", collateralToken: vm.envOr("ARC_MXNB", DEFAULT_MXNB)});
        specs[1] = MarketSpec({symbol: "QCAD", collateralToken: vm.envOr("ARC_QCAD", DEFAULT_QCAD)});
        specs[2] = MarketSpec({symbol: "cirBTC", collateralToken: vm.envOr("ARC_CIRBTC", DEFAULT_CIRBTC)});

        _assertCode("MorphoBlue", address(morpho));
        _assertCode("AdaptiveCurveIrm", irm);
        _assertCode("FxOracle", oracleAddr);
        _assertCode("USDC", usdc);
        for (uint256 i = 0; i < specs.length; i++) {
            _assertCode(specs[i].symbol, specs[i].collateralToken);
        }

        if (!morpho.isIrmEnabled(irm)) revert MorphoIrmNotEnabled(address(morpho), irm);
        if (!morpho.isLltvEnabled(lltv)) revert MorphoLltvNotEnabled(address(morpho), lltv);

        console2.log("============================================");
        console2.log("Arc canonical Morpho markets (USDC loan)");
        console2.log("============================================");
        console2.log("deployer                ", deployer);
        console2.log("morpho (canonical)      ", address(morpho));
        console2.log("irm                     ", irm);
        console2.log("oracle (shared)         ", oracleAddr);
        console2.log("usdc                    ", usdc);
        console2.log("lltv                    ", lltv);
        for (uint256 i = 0; i < specs.length; i++) {
            console2.log("collateral", specs[i].symbol, "                ", specs[i].collateralToken);
        }

        bytes32[3] memory marketIds;
        address[3] memory adapters;

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < specs.length; i++) {
            MorphoOracleAdapter adapter = new MorphoOracleAdapter(oracleAddr, usdc, specs[i].collateralToken);
            MarketParams memory mp = MarketParams({
                loanToken: usdc,
                collateralToken: specs[i].collateralToken,
                oracle: address(adapter),
                irm: irm,
                lltv: lltv
            });
            morpho.createMarket(mp);
            adapters[i] = address(adapter);
            marketIds[i] = _marketId(mp);
        }
        vm.stopBroadcast();

        console2.log("");
        console2.log("Created markets:");
        for (uint256 i = 0; i < specs.length; i++) {
            console2.log("");
            console2.log("symbol             ", specs[i].symbol);
            console2.log("adapter            ", adapters[i]);
            console2.log("marketId          ");
            console2.logBytes32(marketIds[i]);
        }

        string memory manifestPath = vm.envOr(
            "ARC_CANONICAL_MORPHO_MARKETS_PATH",
            string.concat("../deployments/arc-canonical-morpho-markets-", vm.toString(block.chainid), ".json")
        );
        _writeManifest(manifestPath, address(morpho), irm, oracleAddr, usdc, lltv, specs, adapters, marketIds);
    }

    function _marketId(MarketParams memory mp) internal pure returns (bytes32) {
        // Morpho's market id is keccak256 of the abi-encoded MarketParams.
        return keccak256(abi.encode(mp));
    }

    function _assertCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert MissingCode(label, target);
    }

    function _writeManifest(
        string memory path,
        address morpho,
        address irm,
        address oracleAddr,
        address usdc,
        uint256 lltv,
        MarketSpec[3] memory specs,
        address[3] memory adapters,
        bytes32[3] memory marketIds
    ) internal {
        string memory root = "arcCanonicalMorphoMarkets";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "exportedBlockNumber", block.number);
        vm.serializeUint(root, "exportedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "MorphoBlue", morpho);
        vm.serializeAddress(root, "AdaptiveCurveIrm", irm);
        vm.serializeAddress(root, "FxOracle", oracleAddr);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeUint(root, "lltv", lltv);
        for (uint256 i = 0; i < specs.length; i++) {
            string memory key = string.concat("USDC_", specs[i].symbol);
            vm.serializeAddress(root, string.concat(key, "_collateral"), specs[i].collateralToken);
            vm.serializeAddress(root, string.concat(key, "_adapter"), adapters[i]);
            vm.serializeBytes32(root, string.concat(key, "_marketId"), marketIds[i]);
        }
        string memory json = vm.serializeString(
            root,
            "source",
            "DeployArcCanonicalMorphoMarkets.s.sol -- Arc canonical Morpho Labs MorphoBlue"
        );
        vm.writeJson(json, path);
        console2.log("manifest          ", path);
    }
}
