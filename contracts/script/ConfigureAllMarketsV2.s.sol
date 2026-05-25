// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";
import {IFxPerpClearinghouse} from "../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";

/// @notice Configure all 5 perp markets on the V2 clearinghouse stack.
///         Uses the EXACT Sprint-1 market IDs (keccak256 of FX-PERP:symbol/USDC)
///         so the SDK, matcher, and UI remain compatible.
contract ConfigureAllMarketsV2 is Script {
    address internal constant CLEARINGHOUSE = 0xCE3401BD53be4c0a8c7CCb0376b313925f99b8d2;
    address internal constant FUNDING = 0x8b3b63D2031da48e3114871a49CD02B923E388e1;

    uint256 internal constant FIAT_OI_CAP = 500_000_000 * 1_000_000_000_000;
    uint256 internal constant BTC_OI_CAP = 250_000_000 * 1_000_000_000_000;

    uint16 internal constant INIT_MARGIN = 500;
    uint16 internal constant MAINT_MARGIN = 300;
    uint16 internal constant TRADING_FEE = 5;
    uint32 internal constant MAX_LEV = 200_000;

    // Sprint-1 canonical market IDs. The hash includes the FX-PERP: prefix
    // and /USDC suffix. tJPYC/tMXNB use "t" prefix from Sprint-1 testnet
    // naming — these IDs are immutable on-chain identifiers regardless of
    // the display symbol (JPYC, MXNB).
    bytes32 internal constant EURC_ID   = keccak256("FX-PERP:EURC/USDC");    // 0x565a...
    bytes32 internal constant JPYC_ID   = keccak256("FX-PERP:tJPYC/USDC");   // 0x9cca...
    bytes32 internal constant MXNB_ID   = keccak256("FX-PERP:tMXNB/USDC");   // 0xb698...
    bytes32 internal constant CIRBTC_ID = keccak256("FX-PERP:cirBTC/USDC");  // 0x238a...
    bytes32 internal constant AUDF_ID   = keccak256("AUDF");                  // 0x921b...

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        FxPerpClearinghouse ch = FxPerpClearinghouse(CLEARINGHOUSE);
        FxFundingEngine fund = FxFundingEngine(FUNDING);

        FxFundingEngine.FundingConfig memory fc = FxFundingEngine.FundingConfig({
            enabled: true, maxFundingRateBpsPerSecond: 1, fundingVelocityBps: 1
        });

        IFxPerpClearinghouse.MarketConfig memory fiatCfg = IFxPerpClearinghouse.MarketConfig({
            baseToken: address(0), enabled: true,
            initialMarginBps: INIT_MARGIN, maintenanceMarginBps: MAINT_MARGIN,
            tradingFeeBps: TRADING_FEE, maxLeverageBps: MAX_LEV,
            maxOpenInterestUsd: FIAT_OI_CAP, maxSkewUsd: FIAT_OI_CAP
        });

        vm.startBroadcast(pk);

        // EURC/USDC
        fiatCfg.baseToken = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
        ch.configureMarket(EURC_ID, fiatCfg);
        fund.configureFunding(EURC_ID, fc);
        console2.log("EURC/USDC   ", uint256(EURC_ID));

        // tJPYC/USDC (display: JPYC)
        fiatCfg.baseToken = 0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a;
        ch.configureMarket(JPYC_ID, fiatCfg);
        fund.configureFunding(JPYC_ID, fc);
        console2.log("tJPYC/USDC  ", uint256(JPYC_ID));

        // tMXNB/USDC (display: MXNB)
        fiatCfg.baseToken = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
        ch.configureMarket(MXNB_ID, fiatCfg);
        fund.configureFunding(MXNB_ID, fc);
        console2.log("tMXNB/USDC  ", uint256(MXNB_ID));

        // cirBTC/USDC
        fiatCfg.baseToken = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
        fiatCfg.maxOpenInterestUsd = BTC_OI_CAP;
        fiatCfg.maxSkewUsd = BTC_OI_CAP;
        ch.configureMarket(CIRBTC_ID, fiatCfg);
        fund.configureFunding(CIRBTC_ID, fc);
        console2.log("cirBTC/USDC ", uint256(CIRBTC_ID));

        // AUDF/USDC
        fiatCfg.baseToken = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
        fiatCfg.maxOpenInterestUsd = FIAT_OI_CAP;
        fiatCfg.maxSkewUsd = FIAT_OI_CAP;
        ch.configureMarket(AUDF_ID, fiatCfg);
        fund.configureFunding(AUDF_ID, fc);
        console2.log("AUDF/USDC   ", uint256(AUDF_ID));

        vm.stopBroadcast();
        console2.log("All 5 markets configured on V2 clearinghouse");
    }
}
