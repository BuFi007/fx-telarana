// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";

/// @notice Deploys Arc Testnet Morpho markets where each issuer-backed token is
///         the **loan asset** and USDC is the collateral — the inverse of
///         `DeployArcCanonicalMorphoMarkets.s.sol` (which created USDC-loan
///         markets with these assets as collateral).
///
/// Purpose: give the fx-Telaraña stack a native on-chain venue to earn yield
/// on idle non-USDC inventory (privacy pool deposits, perp LP backstop,
/// spot inventory, cross-currency relay reserves). MorphoBlue is permissionless
/// — anyone can `createMarket`; no Morpho governance involvement required.
///
/// Markets (each token loan against USDC collateral, 86% LLTV):
///   * MXNB / USDC
///   * QCAD / USDC
///   * cirBTC / USDC   (LLTV=86% matches the canonical USDC/cirBTC market;
///                      tighten to 0.77e18 / 0.625e18 for production use)
///   * AUDF / USDC
///   * EURC / USDC     (distinct from the Morpho Labs M1 deploy — uses
///                      FxOracle-backed adapter, different oracle address →
///                      different market id, coexists with M1)
///
/// JPYC is intentionally absent — no canonical JPYC token deployed on Arc
/// yet. Add a sixth spec when the issuer ships.
contract DeployArcAssetLoanMorphoMarkets is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_MORPHO = 0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4;
    address internal constant DEFAULT_IRM = 0xBD583cc9807980f9e41f7c8250f594fB6173abE3;
    address internal constant DEFAULT_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant DEFAULT_ORACLE = 0xf9b0356A31BC7125e2eD0DADf8b5957860d42c78;

    address internal constant DEFAULT_MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address internal constant DEFAULT_QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;
    address internal constant DEFAULT_CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
    address internal constant DEFAULT_AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address internal constant DEFAULT_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    uint256 internal constant DEFAULT_LLTV = 0.86e18;

    error WrongChain(uint256 chainId);
    error MissingCode(string label, address target);
    error MorphoIrmNotEnabled(address morpho, address irm);
    error MorphoLltvNotEnabled(address morpho, uint256 lltv);

    struct MarketSpec {
        string symbol;
        address loanToken;
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

        MarketSpec[5] memory specs;
        specs[0] = MarketSpec({symbol: "MXNB",   loanToken: vm.envOr("ARC_MXNB",   DEFAULT_MXNB)});
        specs[1] = MarketSpec({symbol: "QCAD",   loanToken: vm.envOr("ARC_QCAD",   DEFAULT_QCAD)});
        specs[2] = MarketSpec({symbol: "cirBTC", loanToken: vm.envOr("ARC_CIRBTC", DEFAULT_CIRBTC)});
        specs[3] = MarketSpec({symbol: "AUDF",   loanToken: vm.envOr("ARC_AUDF",   DEFAULT_AUDF)});
        specs[4] = MarketSpec({symbol: "EURC",   loanToken: vm.envOr("ARC_EURC",   DEFAULT_EURC)});

        _assertCode("MorphoBlue", address(morpho));
        _assertCode("AdaptiveCurveIrm", irm);
        _assertCode("FxOracle", oracleAddr);
        _assertCode("USDC", usdc);
        for (uint256 i = 0; i < specs.length; i++) {
            _assertCode(specs[i].symbol, specs[i].loanToken);
        }

        if (!morpho.isIrmEnabled(irm)) revert MorphoIrmNotEnabled(address(morpho), irm);
        if (!morpho.isLltvEnabled(lltv)) revert MorphoLltvNotEnabled(address(morpho), lltv);

        console2.log("============================================");
        console2.log("Arc asset-loan Morpho markets (USDC collateral)");
        console2.log("============================================");
        console2.log("deployer                ", deployer);
        console2.log("morpho                  ", address(morpho));
        console2.log("irm                     ", irm);
        console2.log("oracle (shared FxOracle)", oracleAddr);
        console2.log("collateral (USDC)       ", usdc);
        console2.log("lltv                    ", lltv);
        for (uint256 i = 0; i < specs.length; i++) {
            console2.log("loan", specs[i].symbol, "                  ", specs[i].loanToken);
        }

        bytes32[5] memory marketIds;
        address[5] memory adapters;

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < specs.length; i++) {
            // MorphoOracleAdapter constructor takes (fxOracle, loanToken,
            // collateralToken). Internally it calls getMid(collateral, loan)
            // which returns (loan-per-collateral) — the price direction
            // Morpho expects. The adapter is direction-symmetric: works
            // for both USDC-loan/X-collateral and X-loan/USDC-collateral
            // configurations without modification.
            MorphoOracleAdapter adapter = new MorphoOracleAdapter(oracleAddr, specs[i].loanToken, usdc);
            MarketParams memory mp = MarketParams({
                loanToken: specs[i].loanToken,
                collateralToken: usdc,
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
            console2.log("loanToken          ", specs[i].loanToken);
            console2.log("adapter            ", adapters[i]);
            console2.log("marketId          ");
            console2.logBytes32(marketIds[i]);
        }

        string memory manifestPath = vm.envOr(
            "ARC_ASSET_LOAN_MORPHO_MARKETS_PATH",
            string.concat("../deployments/arc-asset-loan-morpho-markets-", vm.toString(block.chainid), ".json")
        );
        _writeManifest(manifestPath, address(morpho), irm, oracleAddr, usdc, lltv, specs, adapters, marketIds);
    }

    function _marketId(MarketParams memory mp) internal pure returns (bytes32) {
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
        MarketSpec[5] memory specs,
        address[5] memory adapters,
        bytes32[5] memory marketIds
    ) internal {
        string memory root = "arcAssetLoanMorphoMarkets";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "exportedBlockNumber", block.number);
        vm.serializeUint(root, "exportedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "MorphoBlue", morpho);
        vm.serializeAddress(root, "AdaptiveCurveIrm", irm);
        vm.serializeAddress(root, "FxOracle", oracleAddr);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeUint(root, "lltv", lltv);
        for (uint256 i = 0; i < specs.length; i++) {
            // Key format: <SYMBOL>_USDC_* (e.g. MXNB_USDC_loan, MXNB_USDC_adapter, MXNB_USDC_marketId).
            // Mirrors the canonical USDC_<SYMBOL>_* layout but inverted so
            // downstream consumers can disambiguate the two market families.
            string memory key = string.concat(specs[i].symbol, "_USDC");
            vm.serializeAddress(root, string.concat(key, "_loan"), specs[i].loanToken);
            vm.serializeAddress(root, string.concat(key, "_adapter"), adapters[i]);
            vm.serializeBytes32(root, string.concat(key, "_marketId"), marketIds[i]);
        }
        string memory json = vm.serializeString(
            root,
            "source",
            "DeployArcAssetLoanMorphoMarkets.s.sol -- Arc asset-loan Morpho markets (USDC collateral)"
        );
        vm.writeJson(json, path);
        console2.log("manifest          ", path);
    }
}
