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

/// @notice Adds QCAD/USDC as a new Arc Testnet perp market without
///         touching the other already-configured markets (EURC, JPYC,
///         MXNB, CIRBTC, AUDF). Idempotent — configureMarket +
///         configureFunding overwrite the existing config for the QCAD
///         marketId if it's already been set.
///
/// Required env:
///   KEEPER_PRIVATE_KEY        funded on Arc; must be DEFAULT_ADMIN_ROLE
///   ARC_PERP_CLEARINGHOUSE    (default 0x7707d1…CaFdC)
///   ARC_PERP_FUNDING          (default 0xE08a14…9518)
///   ARC_FX_ORACLE             (default 0xF181ca…698B — FxOracleV2)
///   ARC_QCAD                  (default 0x23d7CF…825d)
///   PYTH_USD_CAD              (default 0x3112b0…ecca — Pyth USD/CAD, inverted for CAD/USD)
contract ConfigureArcPerpQcad is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_CLEARINGHOUSE = 0x7707d108F6Ce3d95ceA38D3965448F00C21CaFdC;
    address internal constant DEFAULT_FUNDING = 0xE08a146B9081A8dd32203fC5e7B5988352489518;
    address internal constant DEFAULT_ORACLE = 0xF181caF51bD2450211CB9e72d5Cc853d3789698B;
    address internal constant DEFAULT_QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;
    // Pyth USD/CAD feed — base=USD, quote=CAD. We set inverted=true so the
    // oracle converts it to CAD/USD (what the protocol expects: 1 CAD ~= 0.72 USD).
    bytes32 internal constant DEFAULT_PYTH_USD_CAD = 0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca;

    // Match the existing FX pair OI caps — pre-scaled by 1e12 so the
    // matcher's WAD comparison doesn't hit OpenInterestCapExceeded on
    // first fill.
    uint256 internal constant QCAD_OI_CAP = 500_000_000 * 1_000_000_000_000;

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

        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", vm.envUint("KEEPER_PRIVATE_KEY"));
        address deployer = vm.addr(pk);
        address oracle = vm.envOr("ARC_FX_ORACLE", DEFAULT_ORACLE);
        address qcad = vm.envOr("ARC_QCAD", DEFAULT_QCAD);
        bytes32 feedUsdCad = vm.envOr("PYTH_USD_CAD", DEFAULT_PYTH_USD_CAD);
        FxPerpClearinghouse clearinghouse =
            FxPerpClearinghouse(vm.envOr("ARC_PERP_CLEARINGHOUSE", DEFAULT_CLEARINGHOUSE));
        FxFundingEngine funding = FxFundingEngine(vm.envOr("ARC_PERP_FUNDING", DEFAULT_FUNDING));

        console2.log("============================================");
        console2.log("Adding QCAD/USDC to Arc Testnet perp stack");
        console2.log("============================================");
        console2.log("deployer       ", deployer);
        console2.log("clearinghouse  ", address(clearinghouse));
        console2.log("funding        ", address(funding));
        console2.log("oracle         ", oracle);
        console2.log("QCAD token     ", qcad);
        console2.log("Pyth USD/CAD   ", uint256(feedUsdCad));
        console2.log("OI cap (WAD)   ", QCAD_OI_CAP);

        vm.startBroadcast(pk);

        // 1. Configure USD/CAD Pyth feed on the perp oracle for the QCAD
        //    token. Pyth reports USD/CAD (base=USD, quote=CAD), so we set
        //    inverted=true to get CAD/USD pricing the protocol expects
        //    (1 CAD ~= 0.72 USD).
        bool oracleSupportsModern = _oracleSupportsPythFeedConfig(oracle, qcad);
        if (oracleSupportsModern) {
            IPerpOracleFeedAdmin(oracle).setPythFeedConfig(qcad, feedUsdCad, true);
        } else {
            (bool ok,) =
                oracle.call(abi.encodeWithSelector(ILegacyPerpOracleFeedAdmin.setFeed.selector, qcad, feedUsdCad));
            if (!ok) revert OraclePythFeedConfigFailed(oracle, qcad);
        }

        // 2. Register the QCAD/USDC perp market on the clearinghouse +
        //    funding engine. marketId = keccak256("QCAD"), same convention
        //    as the other markets in this stack.
        bytes32 marketId = keccak256(bytes("QCAD"));

        clearinghouse.configureMarket(
            marketId,
            IFxPerpClearinghouse.MarketConfig({
                baseToken: qcad,
                enabled: true,
                initialMarginBps: INITIAL_MARGIN_BPS,
                maintenanceMarginBps: MAINTENANCE_MARGIN_BPS,
                tradingFeeBps: TRADING_FEE_BPS,
                maxLeverageBps: MAX_LEVERAGE_BPS,
                maxOpenInterestUsd: QCAD_OI_CAP,
                maxSkewUsd: QCAD_OI_CAP
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
        console2.log("QCAD marketId  ", uint256(marketId));
        console2.log("Done. Add to perps-config-5042002.json:");
        console2.log("  QCAD_USDC_marketId         = ", uint256(marketId));
        console2.log("  QCAD_USDC_baseToken        = ", qcad);
        console2.log("  QCAD_USDC_maxOpenInterestUsd =", QCAD_OI_CAP);
    }

    function _oracleSupportsPythFeedConfig(address oracle, address token) internal view returns (bool) {
        (bool ok,) = oracle.staticcall(abi.encodeWithSignature("pythFeedInvertedOf(address)", token));
        return ok;
    }
}
