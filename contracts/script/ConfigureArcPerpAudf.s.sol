// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";
import {IFxPerpClearinghouse} from "../src/perp/interfaces/IFxPerpClearinghouse.sol";

interface IPerpOracleFeedAdmin {
    function setPythFeedConfig(address token, bytes32 pythFeedId, bool inverted) external;
}

interface ILegacyPerpOracleFeedAdmin {
    function setFeed(address token, bytes32 pythFeedId) external;
}

/// @notice Adds AUDF/USDC as a new Arc Testnet perp market without
///         touching the other already-configured markets (EURC, tJPYC,
///         tMXNB, cirBTC). Idempotent — configureMarket + configureFunding
///         overwrite the existing config for the AUDF marketId if it's
///         already been set.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY    funded on Arc; must be DEFAULT_ADMIN_ROLE
///   ARC_PERP_CLEARINGHOUSE  (default 0x6A2650...18c5)
///   ARC_PERP_FUNDING        (default 0x88B708...dcf3)
///   ARC_FX_ORACLE           (default 0x77b3A3...2865)
///   ARC_AUDF                (default 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b)
///   PYTH_AUD_USD            (default 0x67a6...854a80 — canonical Pyth AUD/USD)
contract ConfigureArcPerpAudf is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_CLEARINGHOUSE = 0x6A265045D9A3291D2881d77DDC62e2781A2418c5;
    address internal constant DEFAULT_FUNDING = 0x88B70872759E1aA24858746779Cb15ca9F2cdcf3;
    address internal constant DEFAULT_ORACLE = 0x77b3A3B420dB98B01085b8C46a753Ed9879e2865;
    address internal constant DEFAULT_AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    bytes32 internal constant DEFAULT_PYTH_AUD_USD = 0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80;

    // Match the existing TEST_FIAT_OI_CAP in ConfigureArcPerpMarkets — but
    // pre-scaled by 1e12 so the matcher's WAD comparison (raise-arc-max-oi
    // shipped this scaling for the existing markets) doesn't hit the
    // OpenInterestCapExceeded gate on first fill.
    uint256 internal constant AUDF_OI_CAP = 500_000_000 * 1_000_000_000_000;

    uint16 internal constant INITIAL_MARGIN_BPS = 500;
    uint16 internal constant MAINTENANCE_MARGIN_BPS = 300;
    uint16 internal constant TRADING_FEE_BPS = 5;
    uint32 internal constant MAX_LEVERAGE_BPS = 200_000;
    uint256 internal constant MAX_FUNDING_RATE_BPS_PER_SECOND = 1;
    uint256 internal constant FUNDING_VELOCITY_BPS = 1;

    error WrongChain(uint256 chainId);
    error OraclePythFeedConfigFailed(address oracle, address token);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address oracle = vm.envOr("ARC_FX_ORACLE", DEFAULT_ORACLE);
        address audf = vm.envOr("ARC_AUDF", DEFAULT_AUDF);
        bytes32 feedAudUsd = vm.envOr("PYTH_AUD_USD", DEFAULT_PYTH_AUD_USD);
        FxPerpClearinghouse clearinghouse =
            FxPerpClearinghouse(vm.envOr("ARC_PERP_CLEARINGHOUSE", DEFAULT_CLEARINGHOUSE));
        FxFundingEngine funding = FxFundingEngine(vm.envOr("ARC_PERP_FUNDING", DEFAULT_FUNDING));

        console2.log("============================================");
        console2.log("Adding AUDF/USDC to Arc Testnet perp stack");
        console2.log("============================================");
        console2.log("deployer       ", deployer);
        console2.log("clearinghouse  ", address(clearinghouse));
        console2.log("funding        ", address(funding));
        console2.log("oracle         ", oracle);
        console2.log("AUDF token     ", audf);
        console2.log("Pyth AUD/USD   ", uint256(feedAudUsd));
        console2.log("OI cap (WAD)   ", AUDF_OI_CAP);

        vm.startBroadcast(pk);

        // 1. Configure AUD/USD Pyth feed on the perp oracle for the AUDF
        //    token. Pyth reports AUD per USD already in the orientation
        //    the protocol expects (1 AUD ~= 0.66 USD), so inverted=false.
        bool oracleSupportsModern = _oracleSupportsPythFeedConfig(oracle, audf);
        if (oracleSupportsModern) {
            IPerpOracleFeedAdmin(oracle).setPythFeedConfig(audf, feedAudUsd, false);
        } else {
            (bool ok,) =
                oracle.call(abi.encodeWithSelector(ILegacyPerpOracleFeedAdmin.setFeed.selector, audf, feedAudUsd));
            if (!ok) revert OraclePythFeedConfigFailed(oracle, audf);
        }

        // 2. Register the AUDF/USDC perp market on the clearinghouse +
        //    funding engine. marketId computed the same way the other
        //    markets in this stack are computed — keccak256(symbol).
        bytes32 marketId = keccak256(bytes("AUDF"));

        clearinghouse.configureMarket(
            marketId,
            IFxPerpClearinghouse.MarketConfig({
                baseToken: audf,
                enabled: true,
                initialMarginBps: INITIAL_MARGIN_BPS,
                maintenanceMarginBps: MAINTENANCE_MARGIN_BPS,
                tradingFeeBps: TRADING_FEE_BPS,
                maxLeverageBps: MAX_LEVERAGE_BPS,
                maxOpenInterestUsd: AUDF_OI_CAP,
                maxSkewUsd: AUDF_OI_CAP
            })
        );
        funding.configureFunding(
            marketId,
            FxFundingEngine.FundingConfig({
                enabled: true,
                maxFundingRateBpsPerSecond: MAX_FUNDING_RATE_BPS_PER_SECOND,
                fundingVelocityBps: FUNDING_VELOCITY_BPS
            })
        );

        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("AUDF marketId  ", uint256(marketId));
        console2.log("Done. Add to perps-config-5042002.json:");
        console2.log("  AUDF_USDC_marketId         = ", uint256(marketId));
        console2.log("  AUDF_USDC_baseToken        = ", audf);
        console2.log("  AUDF_USDC_maxOpenInterestUsd =", AUDF_OI_CAP);
    }

    function _oracleSupportsPythFeedConfig(address oracle, address token) internal view returns (bool) {
        (bool ok,) = oracle.staticcall(abi.encodeWithSignature("pythFeedInvertedOf(address)", token));
        return ok;
    }
}
