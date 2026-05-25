// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";
import {IFxPerpClearinghouse} from "../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";

/// @notice Configure all 5 perp markets on the V2 clearinghouse stack.
contract ConfigureAllMarketsV2 is Script {
    address internal constant CLEARINGHOUSE = 0x5e3D4d909e1A32071C59DBaCca370e7ef38c697f;
    address internal constant FUNDING = 0x0919f280Cf490E30679255f47F23eebE30444E3b;

    uint256 internal constant FIAT_OI_CAP = 500_000_000 * 1_000_000_000_000;
    uint256 internal constant BTC_OI_CAP = 250_000_000 * 1_000_000_000_000;

    uint16 internal constant INIT_MARGIN = 500;
    uint16 internal constant MAINT_MARGIN = 300;
    uint16 internal constant TRADING_FEE = 5;
    uint32 internal constant MAX_LEV = 200_000;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        FxPerpClearinghouse ch = FxPerpClearinghouse(CLEARINGHOUSE);
        FxFundingEngine fund = FxFundingEngine(FUNDING);

        FxFundingEngine.FundingConfig memory fc = FxFundingEngine.FundingConfig({
            enabled: true, maxFundingRateBpsPerSecond: 1, fundingVelocityBps: 1
        });

        vm.startBroadcast(pk);

        _configMarket(ch, fund, "EURC", 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a, FIAT_OI_CAP, fc);
        _configMarket(ch, fund, "JPYC", 0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a, FIAT_OI_CAP, fc);
        _configMarket(ch, fund, "MXNB", 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461, FIAT_OI_CAP, fc);
        _configMarket(ch, fund, "cirBTC", 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF, BTC_OI_CAP, fc);
        _configMarket(ch, fund, "AUDF", 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b, FIAT_OI_CAP, fc);

        vm.stopBroadcast();
        console2.log("All 5 markets configured on V2 clearinghouse");
    }

    function _configMarket(
        FxPerpClearinghouse ch,
        FxFundingEngine fund,
        string memory symbol,
        address baseToken,
        uint256 oiCap,
        FxFundingEngine.FundingConfig memory fc
    ) internal {
        bytes32 marketId = keccak256(bytes(symbol));
        ch.configureMarket(marketId, IFxPerpClearinghouse.MarketConfig({
            baseToken: baseToken, enabled: true,
            initialMarginBps: INIT_MARGIN, maintenanceMarginBps: MAINT_MARGIN,
            tradingFeeBps: TRADING_FEE, maxLeverageBps: MAX_LEV,
            maxOpenInterestUsd: oiCap, maxSkewUsd: oiCap
        }));
        fund.configureFunding(marketId, fc);
        console2.log(string.concat(symbol, "/USDC configured"));
    }
}
