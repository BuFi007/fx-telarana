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

/// @notice Fuji Phase B-E market bootstrap. This configures the Fuji perp
///         markets that have live Fuji testnet assets and tops protocol
///         liquidity up to a target.
contract ConfigureFujiPerpMarkets is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant FUJI_CHAIN_ID = 43_113;

    address internal constant DEFAULT_USDC = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address internal constant DEFAULT_CLEARINGHOUSE = 0x22013f712190034D8Ee43F3894461c27709E74AC;
    address internal constant DEFAULT_MARGIN = 0x21bB1Bb922b04CbCFD1AD7Bd6788F5251917acb2;
    address internal constant DEFAULT_FUNDING = 0x3a4459dBa18806e700423aAbEA1df1fefc928C6a;
    address internal constant DEFAULT_LIQUIDATION = 0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d;

    address internal constant EURC = 0x5E44db7996c682E92a960b65AC713a54AD815c6B;
    address internal constant MXNB = 0xAB99d44185af87AeB08361588F00F59B0CE85eBb;

    uint16 internal constant INITIAL_MARGIN_BPS = 500;
    uint16 internal constant MAINTENANCE_MARGIN_BPS = 300;
    uint16 internal constant TRADING_FEE_BPS = 5;
    uint32 internal constant MAX_LEVERAGE_BPS = 200_000;
    uint256 internal constant EURC_OI_CAP = 1_000e6;
    uint256 internal constant MXNB_OI_CAP = 500e6;
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
        if (block.chainid != FUJI_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envOr("FUJI_USDC", DEFAULT_USDC);
        FxPerpClearinghouse clearinghouse =
            FxPerpClearinghouse(vm.envOr("FUJI_PERP_CLEARINGHOUSE", DEFAULT_CLEARINGHOUSE));
        FxMarginAccount margin = FxMarginAccount(vm.envOr("FUJI_PERP_MARGIN", DEFAULT_MARGIN));
        FxFundingEngine funding = FxFundingEngine(vm.envOr("FUJI_PERP_FUNDING", DEFAULT_FUNDING));
        FxLiquidationEngine liquidation = FxLiquidationEngine(vm.envOr("FUJI_PERP_LIQUIDATION", DEFAULT_LIQUIDATION));
        address eurc = vm.envOr("FUJI_EURC", EURC);
        address mxnb = vm.envOr("FUJI_MXNB", MXNB);
        uint256 protocolLiquidityTarget =
            vm.envOr("FUJI_PERP_PROTOCOL_LIQUIDITY_TARGET", DEFAULT_PROTOCOL_LIQUIDITY_TARGET);

        console2.log("============================================");
        console2.log("Configuring Fuji Phase B-E perp markets");
        console2.log("============================================");
        console2.log("chainId                    ", block.chainid);
        console2.log("deployer                   ", deployer);
        console2.log("clearinghouse              ", address(clearinghouse));
        console2.log("margin                     ", address(margin));
        console2.log("funding                    ", address(funding));
        console2.log("liquidation                ", address(liquidation));
        console2.log("EURC                       ", eurc);
        console2.log("MXNB                       ", mxnb);
        console2.log("protocol liquidity target  ", protocolLiquidityTarget);

        vm.startBroadcast(pk);
        if (clearinghouse.fundingEngine() != address(funding)) {
            clearinghouse.setFundingEngine(address(funding));
        }
        if (margin.fundingSettlementHook() != address(clearinghouse)) {
            margin.setFundingSettlementHook(address(clearinghouse));
        }

        _configureMarket(clearinghouse, funding, "EURC", eurc, EURC_OI_CAP);
        _configureMarket(clearinghouse, funding, "MXNB", mxnb, MXNB_OI_CAP);

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
        _logMarket("MXNB");
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
