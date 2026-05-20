// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";
import {FxLiquidationEngine} from "../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../src/perp/FxMarginAccount.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";
import {IFxPerpClearinghouse} from "../src/perp/interfaces/IFxPerpClearinghouse.sol";

/// @notice Arc-only Phase B-E market bootstrap. This configures the live
///         testnet perp markets and tops protocol liquidity up to a target.
///         It intentionally does not touch Fuji because trading execution
///         is on Arc.
contract ConfigureArcPerpMarkets is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant DEFAULT_CLEARINGHOUSE = 0x6A265045D9A3291D2881d77DDC62e2781A2418c5;
    address internal constant DEFAULT_MARGIN = 0x35c7cD02cFa0c2889547482B71c1a5114d8439C6;
    address internal constant DEFAULT_FUNDING = 0x88B70872759E1aA24858746779Cb15ca9F2cdcf3;
    address internal constant DEFAULT_LIQUIDATION = 0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2;

    address internal constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant TJPYC = 0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a;
    address internal constant TMXNB = 0xe8F76f90553F50E76731afbeF1ac83a9152fFBEb;
    address internal constant TCHFC = 0x249DBFd4ac17247Cf10098F6C3937F90570b5750;

    uint16 internal constant INITIAL_MARGIN_BPS = 500;
    uint16 internal constant MAINTENANCE_MARGIN_BPS = 300;
    uint16 internal constant TRADING_FEE_BPS = 5;
    uint32 internal constant MAX_LEVERAGE_BPS = 200_000;
    uint256 internal constant EURC_OI_CAP = 1_000e6;
    uint256 internal constant TEST_FIAT_OI_CAP = 500e6;
    uint256 internal constant DEFAULT_PROTOCOL_LIQUIDITY_TARGET = 100e6;

    uint256 internal constant MAX_FUNDING_RATE_BPS_PER_SECOND = 1;
    uint256 internal constant FUNDING_VELOCITY_BPS = 1;
    uint16 internal constant LIQUIDATION_BOUNTY_BPS = 500;
    uint256 internal constant LIQUIDATION_BOUNTY_CAP = 5e6;
    uint256 internal constant MIN_LIQUIDATION_FLAG_DELAY = 60;
    uint256 internal constant LIQUIDATION_FLAG_DELAY = 120;

    error WrongChain(uint256 chainId);
    error UnsafeLiquidationFlagDelay(uint256 delay);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envOr("ARC_USDC", DEFAULT_USDC);
        FxPerpClearinghouse clearinghouse =
            FxPerpClearinghouse(vm.envOr("ARC_PERP_CLEARINGHOUSE", DEFAULT_CLEARINGHOUSE));
        FxMarginAccount margin = FxMarginAccount(vm.envOr("ARC_PERP_MARGIN", DEFAULT_MARGIN));
        FxFundingEngine funding = FxFundingEngine(vm.envOr("ARC_PERP_FUNDING", DEFAULT_FUNDING));
        FxLiquidationEngine liquidation = FxLiquidationEngine(vm.envOr("ARC_PERP_LIQUIDATION", DEFAULT_LIQUIDATION));
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
        console2.log("protocol liquidity target  ", protocolLiquidityTarget);

        vm.startBroadcast(pk);
        if (clearinghouse.fundingEngine() != address(funding)) {
            clearinghouse.setFundingEngine(address(funding));
        }
        if (margin.fundingSettlementHook() != address(clearinghouse)) {
            margin.setFundingSettlementHook(address(clearinghouse));
        }

        _configureMarket(clearinghouse, funding, "EURC", EURC, EURC_OI_CAP);
        _configureMarket(clearinghouse, funding, "tJPYC", TJPYC, TEST_FIAT_OI_CAP);
        _configureMarket(clearinghouse, funding, "tMXNB", TMXNB, TEST_FIAT_OI_CAP);
        _configureMarket(clearinghouse, funding, "tCHFC", TCHFC, TEST_FIAT_OI_CAP);

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
        _logMarket("tJPYC");
        _logMarket("tMXNB");
        _logMarket("tCHFC");
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

    function _marketId(string memory symbol) internal pure returns (bytes32) {
        return keccak256(bytes(string.concat("FX-PERP:", symbol, "/USDC")));
    }

    function _logMarket(string memory symbol) internal pure {
        console2.log(symbol, vm.toString(_marketId(symbol)));
    }
}
