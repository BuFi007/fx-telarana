// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";

/// @notice Deploys the SINGLE Arbitrum MXNB/USDC Morpho lending market that
///         brings Arbitrum to hub parity for this one market. Everything else
///         on Arbitrum stays a spoke.
///
///         Market (mirrors the Arc CANON_USDC_MXNB market):
///           * loan = USDC, collateral = MXNB (Bitso), 86% LLTV
///           * canonical Morpho Blue + AdaptiveCurveIrm
///           * fresh FxOracle wired with USDC/USD + USD/MXN(inverted) Pyth feeds
///           * one MorphoOracleAdapter wrapping the FxOracle for this market
///
/// Parameterized to target Arbitrum One (42161) OR Arbitrum Sepolia (421614)
/// via env. Defaults are filled for Arbitrum One; on Sepolia the operator MUST
/// supply ARB_MORPHO + ARB_IRM (Morpho Labs publishes no canonical Arbitrum
/// Sepolia deployment).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY     — funded on the target Arbitrum chain.
///
/// Chain selection (one of):
///   ARB_CHAIN_ID             — 42161 (One) or 421614 (Sepolia). Defaults to
///                              42161. MUST equal block.chainid (guarded).
///
/// Optional env (Arbitrum One defaults shown; Sepolia overrides required for
/// ARB_MORPHO / ARB_IRM / ARB_PYTH / ARB_USDC / ARB_MXNB):
///   ARB_MORPHO               default 0xBBBB…FFCb (canonical Morpho Blue, One)
///   ARB_IRM                  default 0x870aC11D… (AdaptiveCurveIrm, One)
///   ARB_PYTH                 default 0xff1a0f47… (Pyth pull oracle, One)
///   ARB_USDC                 default 0xaf88d065… (native Circle USDC, One)
///   ARB_MXNB                 default 0xf197ffc2… (Bitso MXNB, One)
///   ARB_LLTV                 default 0.86e18
///   FX_ORACLE_MAX_AGE_S      default 300
///   FX_ORACLE_MAX_DEV_BPS    default 50
///   FX_ORACLE_MAX_CONF_BPS   default 30
///   PYTH_USDC_USD            default 0xeaa0…c94a (canonical Pyth USDC/USD)
///   PYTH_USD_MXN             default 0xe13b…b77ca (canonical Pyth USD/MXN)
///   PYTH_USD_MXN_INVERTED    default true — Pyth reports USD/MXN (MXN per USD
///                            ≈ 17). We need USD per MXNB (≈ 0.058). Set false
///                            ONLY if you supply a feed already quoting USD/MXNB.
///   ARB_MXNB_MARKET_PATH     manifest output path; defaults per chain to
///                            ../deployments/morpho-arbitrum-{one|sepolia}.json
contract DeployArbMxnbMarket is Script {
    uint256 internal constant ARB_ONE = 42_161;
    uint256 internal constant ARB_SEPOLIA = 421_614;

    // Arbitrum One defaults (verified addresses).
    address internal constant DEFAULT_ONE_MORPHO = 0x6c247b1F6182318877311737BaC0844bAa518F5e;
    address internal constant DEFAULT_ONE_IRM    = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address internal constant DEFAULT_ONE_PYTH   = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C;
    address internal constant DEFAULT_ONE_USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant DEFAULT_ONE_MXNB   = 0xF197FFC28c23E0309B5559e7a166f2c6164C80aA;

    /// USDC/USD on Pyth.
    bytes32 internal constant DEFAULT_PYTH_USDC_USD =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    /// Pyth USD/MXN feed (1 USD = X MXN ≈ 17). Inverted to USD-per-MXNB.
    bytes32 internal constant DEFAULT_PYTH_USD_MXN =
        0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;

    uint256 internal constant DEFAULT_LLTV = 0.86e18;

    error WrongChain(uint256 expected, uint256 actual);
    error UnsupportedChain(uint256 chainId);
    error MissingCode(string label, address target);
    error MissingAddress(string label);
    error MorphoIrmNotEnabled(address morpho, address irm);
    error MorphoLltvNotEnabled(address morpho, uint256 lltv);

    function run() external {
        uint256 targetChain = vm.envOr("ARB_CHAIN_ID", ARB_ONE);
        if (targetChain != ARB_ONE && targetChain != ARB_SEPOLIA) revert UnsupportedChain(targetChain);
        if (block.chainid != targetChain) revert WrongChain(targetChain, block.chainid);
        bool isOne = targetChain == ARB_ONE;

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // On Sepolia there is no canonical Morpho deployment, so morpho/irm
        // have NO defaults — the operator must supply them. address(0) →
        // _requireAddress reverts before any broadcast.
        IMorpho morpho = IMorpho(_requireAddress("ARB_MORPHO", vm.envOr("ARB_MORPHO", isOne ? DEFAULT_ONE_MORPHO : address(0))));
        address irm    = _requireAddress("ARB_IRM",    vm.envOr("ARB_IRM",    isOne ? DEFAULT_ONE_IRM  : address(0)));
        address pyth   = _requireAddress("ARB_PYTH",   vm.envOr("ARB_PYTH",   isOne ? DEFAULT_ONE_PYTH : address(0)));
        address usdc   = _requireAddress("ARB_USDC",   vm.envOr("ARB_USDC",   isOne ? DEFAULT_ONE_USDC : address(0)));
        address mxnb   = _requireAddress("ARB_MXNB",   vm.envOr("ARB_MXNB",   isOne ? DEFAULT_ONE_MXNB : address(0)));

        uint256 lltv    = vm.envOr("ARB_LLTV", DEFAULT_LLTV);
        uint256 maxAge  = vm.envOr("FX_ORACLE_MAX_AGE_S",    uint256(300));
        uint256 maxDev  = vm.envOr("FX_ORACLE_MAX_DEV_BPS",  uint256(50));
        uint256 maxConf = vm.envOr("FX_ORACLE_MAX_CONF_BPS", uint256(30));
        bytes32 feedUsdc   = vm.envOr("PYTH_USDC_USD", DEFAULT_PYTH_USDC_USD);
        bytes32 feedUsdMxn = vm.envOr("PYTH_USD_MXN",  DEFAULT_PYTH_USD_MXN);
        bool mxnInverted   = vm.envOr("PYTH_USD_MXN_INVERTED", true);

        _assertCode("MorphoBlue", address(morpho));
        _assertCode("AdaptiveCurveIrm", irm);
        _assertCode("Pyth", pyth);
        _assertCode("USDC", usdc);
        _assertCode("MXNB", mxnb);

        if (!morpho.isIrmEnabled(irm)) revert MorphoIrmNotEnabled(address(morpho), irm);
        if (!morpho.isLltvEnabled(lltv)) revert MorphoLltvNotEnabled(address(morpho), lltv);

        console2.log("============================================");
        console2.log("Arbitrum MXNB/USDC Morpho market (USDC loan)");
        console2.log("============================================");
        console2.log("chainId                 ", block.chainid);
        console2.log("deployer                ", deployer);
        console2.log("morpho (canonical)      ", address(morpho));
        console2.log("irm                     ", irm);
        console2.log("pyth                    ", pyth);
        console2.log("usdc                    ", usdc);
        console2.log("mxnb (collateral)       ", mxnb);
        console2.log("lltv                    ", lltv);
        console2.log("MXN feed inverted       ", mxnInverted);

        vm.startBroadcast(pk);

        // 1) Fresh FxOracle wired for USDC + MXNB. Admin role → deployer for
        //    bootstrap; ops hands DEFAULT_ADMIN_ROLE off to a timelock/multisig
        //    after smoke (same atomic-handoff pattern as the Fuji/Arc deploys).
        FxOracle oracle = new FxOracle(pyth, deployer, maxAge, maxDev, maxConf);
        require(oracle.maxOracleAge()     == maxAge,  "maxOracleAge mismatch");
        require(oracle.maxDeviationBps()  == maxDev,  "maxDeviationBps mismatch");
        require(oracle.maxConfidenceBps() == maxConf, "maxConfidenceBps mismatch");

        oracle.setFeed(usdc, feedUsdc);                          // USDC/USD, not inverted
        oracle.setPythFeedConfig(mxnb, feedUsdMxn, mxnInverted); // USD/MXN → USD-per-MXNB

        // 2) One MorphoOracleAdapter: (fxOracle, loanToken=USDC, collateral=MXNB).
        MorphoOracleAdapter adapter = new MorphoOracleAdapter(address(oracle), usdc, mxnb);

        // 3) Create the canonical Morpho market: loan=USDC, collateral=MXNB.
        MarketParams memory mp = MarketParams({
            loanToken: usdc,
            collateralToken: mxnb,
            oracle: address(adapter),
            irm: irm,
            lltv: lltv
        });
        morpho.createMarket(mp);
        bytes32 marketId = _marketId(mp);

        vm.stopBroadcast();

        console2.log("");
        console2.log("FxOracle (USDC+MXNB)  ", address(oracle));
        console2.log("MorphoOracleAdapter   ", address(adapter));
        console2.log("CANON_USDC_MXNB marketId");
        console2.logBytes32(marketId);

        string memory defaultPath = string.concat(
            "../deployments/morpho-arbitrum-",
            isOne ? "one" : "sepolia",
            ".json"
        );
        string memory manifestPath = vm.envOr("ARB_MXNB_MARKET_PATH", defaultPath);
        _writeManifest(manifestPath, address(morpho), irm, pyth, address(oracle), usdc, mxnb, lltv, address(adapter), marketId);
    }

    function _marketId(MarketParams memory mp) internal pure returns (bytes32) {
        return keccak256(abi.encode(mp));
    }

    function _assertCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert MissingCode(label, target);
    }

    function _requireAddress(string memory label, address value) internal pure returns (address) {
        if (value == address(0)) revert MissingAddress(label);
        return value;
    }

    function _writeManifest(
        string memory path,
        address morpho,
        address irm,
        address pyth,
        address oracleAddr,
        address usdc,
        address mxnb,
        uint256 lltv,
        address adapter,
        bytes32 marketId
    ) internal {
        string memory root = "arbMxnbMarket";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "exportedBlockNumber", block.number);
        vm.serializeUint(root, "exportedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "MorphoBlue", morpho);
        vm.serializeAddress(root, "AdaptiveCurveIrm", irm);
        vm.serializeAddress(root, "Pyth", pyth);
        vm.serializeAddress(root, "FxOracle", oracleAddr);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeAddress(root, "MXNB", mxnb);
        vm.serializeUint(root, "lltv", lltv);
        vm.serializeAddress(root, "USDC_MXNB_collateral", mxnb);
        vm.serializeAddress(root, "USDC_MXNB_adapter", adapter);
        vm.serializeBytes32(root, "USDC_MXNB_marketId", marketId);
        string memory json = vm.serializeString(
            root,
            "source",
            "DeployArbMxnbMarket.s.sol -- Arbitrum canonical Morpho MXNB/USDC market"
        );
        vm.writeJson(json, path);
        console2.log("manifest          ", path);
    }
}
