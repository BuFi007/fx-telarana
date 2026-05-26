// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";
import {FxLiquidationEngine} from "../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../src/perp/FxMarginAccount.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";
import {IFxPerpClearinghouse} from "../src/perp/interfaces/IFxPerpClearinghouse.sol";

interface IPerpOracleFeedAdmin {
    function setPythFeedConfig(address token, bytes32 pythFeedId, bool inverted) external;
    function setRedstoneFeed(address token, bytes32 redstoneFeedId) external;
}

interface ILegacyPerpOracleFeedAdmin {
    function setFeed(address token, bytes32 pythFeedId) external;
}

/// @notice Arc-only Phase B-E market bootstrap. This configures the live
///         testnet perp markets and tops protocol liquidity up to a target.
///         It intentionally does not touch Fuji because trading execution
///         is on Arc.
contract ConfigureArcPerpMarkets is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant DEFAULT_ARC_PERP_ORACLE = 0xF181caF51bD2450211CB9e72d5Cc853d3789698B;
    address internal constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;
    // Market id remains FX-PERP:tMXNB/USDC for SDK compatibility, but the
    // base token is the issuer-backed Arc MXNB deployment.
    address internal constant TMXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    // tCHFC market intentionally removed — the on-chain entry at
    // marketId(tCHFC) was configured by an earlier broadcast but is no
    // longer listed by configure / readiness / SDK manifests. The
    // clearinghouse has no on-chain disable path (configureMarket rejects
    // `enabled: false`), so the artifact stays but is unsurfaced.
    address internal constant CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;

    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant PYTH_JPY_USD = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 internal constant REDSTONE_BTC = "BTC";
    bytes32 internal constant REDSTONE_JPY = "JPY";

    uint16 internal constant INITIAL_MARGIN_BPS = 500;
    uint16 internal constant MAINTENANCE_MARGIN_BPS = 300;
    uint16 internal constant TRADING_FEE_BPS = 5;
    uint32 internal constant MAX_LEVERAGE_BPS = 200_000;
    uint256 internal constant EURC_OI_CAP = 500_000_000 * 1_000_000_000_000;
    uint256 internal constant TEST_FIAT_OI_CAP = 500_000_000 * 1_000_000_000_000;
    uint256 internal constant TEST_CRYPTO_OI_CAP = 250_000_000 * 1_000_000_000_000;
    uint256 internal constant DEFAULT_PROTOCOL_LIQUIDITY_TARGET = 100e6;

    uint256 internal constant MAX_FUNDING_RATE_BPS_PER_SECOND = 1;
    uint256 internal constant FUNDING_VELOCITY_BPS = 1;
    uint16 internal constant LIQUIDATION_BOUNTY_BPS = 500;
    uint256 internal constant LIQUIDATION_BOUNTY_CAP = 5e6;
    uint256 internal constant MIN_LIQUIDATION_FLAG_DELAY = 60;
    uint256 internal constant LIQUIDATION_FLAG_DELAY = 120;

    error WrongChain(uint256 chainId);
    error OraclePythFeedConfigFailed(address oracle, address token);
    error OracleRedstoneFeedConfigFailed(address oracle, address token);
    error UnsafeLiquidationFlagDelay(uint256 delay);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envOr("ARC_USDC", DEFAULT_USDC);
        address oracle = vm.envOr("ARC_FX_ORACLE", DEFAULT_ARC_PERP_ORACLE);
        address cirbtc = vm.envOr("ARC_CIRBTC", CIRBTC);
        address jpyc = vm.envOr("ARC_JPYC", JPYC);
        FxPerpClearinghouse clearinghouse = FxPerpClearinghouse(vm.envAddress("ARC_PERP_CLEARINGHOUSE"));
        FxMarginAccount margin = FxMarginAccount(vm.envAddress("ARC_PERP_MARGIN"));
        FxFundingEngine funding = FxFundingEngine(vm.envAddress("ARC_PERP_FUNDING"));
        FxLiquidationEngine liquidation = FxLiquidationEngine(vm.envAddress("ARC_PERP_LIQUIDATION"));
        bool oracleSupportsPythFeedConfig = _oracleSupportsPythFeedConfig(oracle, cirbtc);
        uint256 protocolLiquidityTarget =
            vm.envOr("ARC_PERP_PROTOCOL_LIQUIDITY_TARGET", DEFAULT_PROTOCOL_LIQUIDITY_TARGET);

        console2.log("============================================");
        console2.log("Configuring Arc Phase B-E perp markets");
        console2.log("============================================");
        console2.log("chainId                    ", block.chainid);
        console2.log("deployer                   ", deployer);
        console2.log("clearinghouse              ", address(clearinghouse));
        console2.log("margin                     ", address(margin));
        console2.log("funding                    ", address(funding));
        console2.log("liquidation                ", address(liquidation));
        console2.log("oracle                     ", oracle);
        console2.log("cirBTC                     ", cirbtc);
        console2.log("JPYC                       ", jpyc);
        console2.log("oracle supports setPythFeedConfig", oracleSupportsPythFeedConfig);
        console2.log("protocol liquidity target  ", protocolLiquidityTarget);

        vm.startBroadcast(pk);
        if (clearinghouse.fundingEngine() != address(funding)) {
            clearinghouse.setFundingEngine(address(funding));
        }
        if (margin.fundingSettlementHook() != address(clearinghouse)) {
            margin.setFundingSettlementHook(address(clearinghouse));
        }

        _configureCirBtcOracle(oracle, cirbtc, oracleSupportsPythFeedConfig);
        _configureJpycOracle(oracle, jpyc, oracleSupportsPythFeedConfig);
        _configureMarket(clearinghouse, funding, "EURC", EURC, EURC_OI_CAP);
        _configureMarket(clearinghouse, funding, "JPYC", jpyc, TEST_FIAT_OI_CAP);
        _configureMarket(clearinghouse, funding, "tMXNB", TMXNB, TEST_FIAT_OI_CAP);
        _configureMarket(clearinghouse, funding, "cirBTC", cirbtc, TEST_CRYPTO_OI_CAP);

        _validateLiquidationDelay();
        liquidation.configureLiquidation(
            FxLiquidationEngine.LiquidationConfig({
                bountyBps: LIQUIDATION_BOUNTY_BPS, bountyCap: LIQUIDATION_BOUNTY_CAP, flagDelay: LIQUIDATION_FLAG_DELAY
            })
        );

        uint256 currentLiquidity = margin.protocolLiquidity();
        if (currentLiquidity < protocolLiquidityTarget) {
            uint256 topUp = protocolLiquidityTarget - currentLiquidity;
            IERC20(usdc).forceApprove(address(margin), topUp);
            margin.depositProtocolLiquidity(topUp);
        }
        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("Configured markets:");
        _logMarket("EURC");
        _logMarket("JPYC");
        _logMarket("tMXNB");
        _logMarket("cirBTC");
        console2.log("liquidation bounty bps     ", LIQUIDATION_BOUNTY_BPS);
        console2.log("liquidation bounty cap     ", LIQUIDATION_BOUNTY_CAP);
        console2.log("liquidation flag delay     ", LIQUIDATION_FLAG_DELAY);
        console2.log("protocol liquidity         ", margin.protocolLiquidity());
    }

    function _validateLiquidationDelay() internal pure {
        if (LIQUIDATION_FLAG_DELAY < MIN_LIQUIDATION_FLAG_DELAY) {
            revert UnsafeLiquidationFlagDelay(LIQUIDATION_FLAG_DELAY);
        }
    }

    function _configureMarket(
        FxPerpClearinghouse clearinghouse,
        FxFundingEngine funding,
        string memory symbol,
        address baseToken,
        uint256 oiCap
    ) internal {
        bytes32 marketId = _marketId(symbol);
        clearinghouse.configureMarket(
            marketId,
            IFxPerpClearinghouse.MarketConfig({
                baseToken: baseToken,
                enabled: true,
                initialMarginBps: INITIAL_MARGIN_BPS,
                maintenanceMarginBps: MAINTENANCE_MARGIN_BPS,
                tradingFeeBps: TRADING_FEE_BPS,
                maxLeverageBps: MAX_LEVERAGE_BPS,
                maxOpenInterestUsd: oiCap,
                maxSkewUsd: oiCap
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
    }

    function _configureCirBtcOracle(address oracle, address cirbtc, bool supportsPythFeedConfig) internal {
        if (supportsPythFeedConfig) {
            IPerpOracleFeedAdmin(oracle).setPythFeedConfig(cirbtc, PYTH_BTC_USD, false);
        } else {
            // The live Arc perp oracle predates inverted-feed support and only
            // exposes setFeed(address,bytes32). BTC/USD does not need inversion.
            (bool pythOk,) =
                oracle.call(abi.encodeWithSelector(ILegacyPerpOracleFeedAdmin.setFeed.selector, cirbtc, PYTH_BTC_USD));
            if (!pythOk) revert OraclePythFeedConfigFailed(oracle, cirbtc);
        }

        (bool redstoneOk,) =
            oracle.call(abi.encodeWithSelector(IPerpOracleFeedAdmin.setRedstoneFeed.selector, cirbtc, REDSTONE_BTC));
        if (!redstoneOk) revert OracleRedstoneFeedConfigFailed(oracle, cirbtc);
    }

    function _configureJpycOracle(address oracle, address jpyc, bool supportsPythFeedConfig) internal {
        if (supportsPythFeedConfig) {
            IPerpOracleFeedAdmin(oracle).setPythFeedConfig(jpyc, PYTH_JPY_USD, false);
        } else {
            (bool pythOk,) =
                oracle.call(abi.encodeWithSelector(ILegacyPerpOracleFeedAdmin.setFeed.selector, jpyc, PYTH_JPY_USD));
            if (!pythOk) revert OraclePythFeedConfigFailed(oracle, jpyc);
        }

        (bool redstoneOk,) =
            oracle.call(abi.encodeWithSelector(IPerpOracleFeedAdmin.setRedstoneFeed.selector, jpyc, REDSTONE_JPY));
        if (!redstoneOk) revert OracleRedstoneFeedConfigFailed(oracle, jpyc);
    }

    function _oracleSupportsPythFeedConfig(address oracle, address token) internal view returns (bool) {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("pythFeedInvertedOf(address)", token));
        return ok && data.length >= 32;
    }

    function _marketId(string memory symbol) internal pure returns (bytes32) {
        return keccak256(bytes(string.concat("FX-PERP:", symbol, "/USDC")));
    }

    function _logMarket(string memory symbol) internal pure {
        console2.log(symbol, vm.toString(_marketId(symbol)));
    }
}
