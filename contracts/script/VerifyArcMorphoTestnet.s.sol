// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IMorpho, Id, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

interface IERC4626Asset {
    function asset() external view returns (address);
}

/// @notice Read-only gate for Morpho Labs' Arc testnet deployment.
/// @dev Run before any fresh Arc hub broadcast:
///      forge script contracts/script/VerifyArcMorphoTestnet.s.sol:VerifyArcMorphoTestnet \
///        --root contracts --rpc-url "$ARC_TESTNET_RPC_URL" -vv
contract VerifyArcMorphoTestnet is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant MORPHO_BLUE = 0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4;
    address internal constant ADAPTIVE_CURVE_IRM = 0xBD583cc9807980f9e41f7c8250f594fB6173abE3;
    address internal constant MORPHO_CHAINLINK_ORACLE_V2_FACTORY = 0xEBef760B0CA0d1Fa9578f47001A184Ee53EaE839;
    address internal constant VAULT_V2_FACTORY = 0x6b7F638B64539F83810A1f6ea81C703b561C3Be6;
    address internal constant MORPHO_MARKET_V1_ADAPTER_V2_FACTORY = 0x9372EbEDF2C64344817c67dAeD99512F4b9DC434;
    address internal constant REGISTRY_LIST = 0xcba6be0EF65176CE7D440A4a93657fb2dd84200c;

    address internal constant DUMMY_VAULT = 0xAabbeF1D3971c710276ed41eC791BbE14CdB8E88;
    address internal constant DUMMY_VAULT_TOKEN = 0x3600000000000000000000000000000000000000;
    bytes32 internal constant DUMMY_MARKET_ID = 0xdd8df39474d60473f49ccc92b363ff4784a09b29e423b4516d18bf8b6ef60d3d;
    address internal constant DUMMY_MARKET_COLLATERAL = 0x44cEe9E472C34b2f0d9710CD8aBd02dadb912761;
    address internal constant DUMMY_MARKET_ORACLE = 0xCef3019D0eb50162f16c80B3165384c05c266F7a;

    uint256 internal constant REQUIRED_LLTV = 0.86e18;

    error WrongChain(uint256 actual, uint256 expected);
    error MissingCode(string label, address target);
    error UnexpectedAddress(string label, address actual, address expected);
    error UnexpectedUint(string label, uint256 actual, uint256 expected);
    error MorphoIrmNotEnabled(address irm);
    error MorphoLltvNotEnabled(uint256 lltv);

    function run() external view {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid, ARC_CHAIN_ID);

        _requireCode("MorphoBlue", MORPHO_BLUE);
        _requireCode("AdaptiveCurveIrm", ADAPTIVE_CURVE_IRM);
        _requireCode("MorphoChainlinkOracleV2Factory", MORPHO_CHAINLINK_ORACLE_V2_FACTORY);
        _requireCode("VaultV2Factory", VAULT_V2_FACTORY);
        _requireCode("MorphoMarketV1AdapterV2Factory", MORPHO_MARKET_V1_ADAPTER_V2_FACTORY);
        _requireCode("RegistryList", REGISTRY_LIST);
        _requireCode("DummyVault", DUMMY_VAULT);
        _requireCode("DummyVaultToken", DUMMY_VAULT_TOKEN);

        IMorpho morpho = IMorpho(MORPHO_BLUE);
        if (!morpho.isIrmEnabled(ADAPTIVE_CURVE_IRM)) revert MorphoIrmNotEnabled(ADAPTIVE_CURVE_IRM);
        if (!morpho.isLltvEnabled(REQUIRED_LLTV)) revert MorphoLltvNotEnabled(REQUIRED_LLTV);
        if (IERC4626Asset(DUMMY_VAULT).asset() != DUMMY_VAULT_TOKEN) {
            revert UnexpectedAddress("dummy vault asset", IERC4626Asset(DUMMY_VAULT).asset(), DUMMY_VAULT_TOKEN);
        }

        MarketParams memory p = morpho.idToMarketParams(Id.wrap(DUMMY_MARKET_ID));
        if (p.loanToken != DUMMY_VAULT_TOKEN) {
            revert UnexpectedAddress("dummy loan token", p.loanToken, DUMMY_VAULT_TOKEN);
        }
        if (p.collateralToken != DUMMY_MARKET_COLLATERAL) {
            revert UnexpectedAddress("dummy collateral", p.collateralToken, DUMMY_MARKET_COLLATERAL);
        }
        if (p.oracle != DUMMY_MARKET_ORACLE) revert UnexpectedAddress("dummy oracle", p.oracle, DUMMY_MARKET_ORACLE);
        if (p.irm != ADAPTIVE_CURVE_IRM) revert UnexpectedAddress("dummy irm", p.irm, ADAPTIVE_CURVE_IRM);
        if (p.lltv != REQUIRED_LLTV) revert UnexpectedUint("dummy lltv", p.lltv, REQUIRED_LLTV);
        _requireCode("DummyMarketCollateral", p.collateralToken);
        _requireCode("DummyMarketOracle", p.oracle);

        console2.log("Arc Morpho testnet deployment verified");
        console2.log("MorphoBlue", MORPHO_BLUE);
        console2.log("AdaptiveCurveIrm", ADAPTIVE_CURVE_IRM);
        console2.log("DummyVault", DUMMY_VAULT);
        console2.log("DummyMarketCollateral", p.collateralToken);
    }

    function _requireCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert MissingCode(label, target);
    }
}
