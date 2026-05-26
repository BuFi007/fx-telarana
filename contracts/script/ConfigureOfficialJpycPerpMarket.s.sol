// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";
import {IFxPerpClearinghouse} from "../src/perp/interfaces/IFxPerpClearinghouse.sol";

interface IJpycOracleFeedAdmin {
    function setPythFeedConfig(address token, bytes32 pythFeedId, bool inverted) external;
    function setRedstoneFeed(address token, bytes32 redstoneFeedId) external;
}

interface ILegacyJpycOracleFeedAdmin {
    function setFeed(address token, bytes32 pythFeedId) external;
}

/// @notice Reconfigures the Arc JPYC/USDC perp market to the official JPYC token.
contract ConfigureOfficialJpycPerpMarket is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;
    address internal constant DEFAULT_FX_ORACLE = 0xF181caF51bD2450211CB9e72d5Cc853d3789698B;
    address internal constant DEFAULT_CLEARINGHOUSE = 0xCE3401BD53be4c0a8c7CCb0376b313925f99b8d2;
    address internal constant DEFAULT_FUNDING = 0x8b3b63D2031da48e3114871a49CD02B923E388e1;

    bytes32 internal constant JPYC_MARKET_ID = keccak256("FX-PERP:JPYC/USDC");
    bytes32 internal constant PYTH_JPY_USD =
        0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 internal constant REDSTONE_JPY = "JPY";

    uint16 internal constant INITIAL_MARGIN_BPS = 500;
    uint16 internal constant MAINTENANCE_MARGIN_BPS = 300;
    uint16 internal constant TRADING_FEE_BPS = 5;
    uint32 internal constant MAX_LEVERAGE_BPS = 200_000;
    // Match the live V2 Arc perp stack caps used by ConfigureAllMarketsV2.
    uint256 internal constant FIAT_OI_CAP = 500_000_000 * 1_000_000_000_000;
    uint256 internal constant MAX_FUNDING_RATE_BPS_PER_SECOND = 1;
    uint256 internal constant FUNDING_VELOCITY_BPS = 1;

    error WrongChain(uint256 chainId);
    error OraclePythFeedConfigFailed(address oracle, address token);
    error OracleRedstoneFeedConfigFailed(address oracle, address token);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address jpyc = vm.envOr("ARC_JPYC", DEFAULT_JPYC);
        address oracle = vm.envOr("ARC_FX_ORACLE", DEFAULT_FX_ORACLE);
        FxPerpClearinghouse clearinghouse =
            FxPerpClearinghouse(vm.envOr("ARC_PERP_CLEARINGHOUSE", DEFAULT_CLEARINGHOUSE));
        FxFundingEngine funding = FxFundingEngine(vm.envOr("ARC_PERP_FUNDING", DEFAULT_FUNDING));
        bool supportsPythFeedConfig = _oracleSupportsPythFeedConfig(oracle, jpyc);

        console2.log("============================================");
        console2.log("Configuring official JPYC/USDC perp market");
        console2.log("============================================");
        console2.log("chainId       ", block.chainid);
        console2.log("deployer      ", deployer);
        console2.log("JPYC          ", jpyc);
        console2.log("oracle        ", oracle);
        console2.log("clearinghouse ", address(clearinghouse));
        console2.log("funding       ", address(funding));
        console2.logBytes32(JPYC_MARKET_ID);

        vm.startBroadcast(pk);
        _configureJpycOracle(oracle, jpyc, supportsPythFeedConfig);
        clearinghouse.configureMarket(
            JPYC_MARKET_ID,
            IFxPerpClearinghouse.MarketConfig({
                baseToken: jpyc,
                enabled: true,
                initialMarginBps: INITIAL_MARGIN_BPS,
                maintenanceMarginBps: MAINTENANCE_MARGIN_BPS,
                tradingFeeBps: TRADING_FEE_BPS,
                maxLeverageBps: MAX_LEVERAGE_BPS,
                maxOpenInterestUsd: FIAT_OI_CAP,
                maxSkewUsd: FIAT_OI_CAP
            })
        );
        funding.configureFunding(
            JPYC_MARKET_ID,
            FxFundingEngine.FundingConfig({
                enabled: true,
                maxFundingRateBpsPerSecond: MAX_FUNDING_RATE_BPS_PER_SECOND,
                fundingVelocityBps: FUNDING_VELOCITY_BPS
            })
        );
        vm.stopBroadcast();

        string memory defaultPath =
            string.concat("../deployments/official-jpyc-perp-market-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("OFFICIAL_JPYC_PERP_MARKET_PATH", defaultPath);
        _writeManifest(path, deployer, oracle, address(clearinghouse), address(funding), jpyc);

        console2.log("Configured JPYC/USDC market");
        console2.log("manifest", path);
    }

    function _configureJpycOracle(address oracle, address jpyc, bool supportsPythFeedConfig) internal {
        if (supportsPythFeedConfig) {
            IJpycOracleFeedAdmin(oracle).setPythFeedConfig(jpyc, PYTH_JPY_USD, false);
        } else {
            (bool pythOk,) =
                oracle.call(abi.encodeWithSelector(ILegacyJpycOracleFeedAdmin.setFeed.selector, jpyc, PYTH_JPY_USD));
            if (!pythOk) revert OraclePythFeedConfigFailed(oracle, jpyc);
        }

        (bool redstoneOk,) =
            oracle.call(abi.encodeWithSelector(IJpycOracleFeedAdmin.setRedstoneFeed.selector, jpyc, REDSTONE_JPY));
        if (!redstoneOk) revert OracleRedstoneFeedConfigFailed(oracle, jpyc);
    }

    function _oracleSupportsPythFeedConfig(address oracle, address token) internal view returns (bool) {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("pythFeedInvertedOf(address)", token));
        return ok && data.length >= 32;
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address oracle,
        address clearinghouse,
        address funding,
        address jpyc
    ) internal {
        string memory root = "officialJpycPerpMarket";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "configuredBlockNumber", block.number);
        vm.serializeUint(root, "configuredBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "FxOracle", oracle);
        vm.serializeAddress(root, "FxPerpClearinghouse", clearinghouse);
        vm.serializeAddress(root, "FxFundingEngine", funding);
        vm.serializeAddress(root, "JPYC", jpyc);
        vm.serializeBytes32(root, "JPYC_USDC_marketId", JPYC_MARKET_ID);
        vm.serializeBytes32(root, "JPYC_USDC_pythFeedId", PYTH_JPY_USD);
        vm.serializeString(root, "JPYC_USDC_redstoneFeedId", "JPY");
        vm.serializeUint(root, "JPYC_USDC_initialMarginBps", INITIAL_MARGIN_BPS);
        vm.serializeUint(root, "JPYC_USDC_maintenanceMarginBps", MAINTENANCE_MARGIN_BPS);
        vm.serializeUint(root, "JPYC_USDC_tradingFeeBps", TRADING_FEE_BPS);
        vm.serializeUint(root, "JPYC_USDC_maxLeverageBps", MAX_LEVERAGE_BPS);
        vm.serializeUint(root, "JPYC_USDC_maxOpenInterestUsd", FIAT_OI_CAP);
        string memory json = vm.serializeUint(root, "JPYC_USDC_maxSkewUsd", FIAT_OI_CAP);
        vm.writeJson(json, path);
    }
}
