// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";
import {FxHealthChecker} from "../src/perp/FxHealthChecker.sol";
import {FxLiquidationEngine} from "../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../src/perp/FxMarginAccount.sol";
import {FxOrderSettlement} from "../src/perp/FxOrderSettlement.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";
import {IFxPerpClearinghouse} from "../src/perp/interfaces/IFxPerpClearinghouse.sol";

/// @notice Shared Arc Phase B-E perp deployment-readiness checks. These scripts
///         are read-only and intentionally never broadcast transactions.
abstract contract ArcPerpConfigReadinessBase is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_ADMIN = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;
    address internal constant DEFAULT_USDC = 0x3600000000000000000000000000000000000000;

    address internal constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant TJPYC = 0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a;
    address internal constant TMXNB = 0xe8F76f90553F50E76731afbeF1ac83a9152fFBEb;
    // tCHFC removed from the listed surface — see ConfigureArcPerpMarkets
    // for the on-chain artifact note.
    address internal constant CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;

    uint16 internal constant INITIAL_MARGIN_BPS = 500;
    uint16 internal constant MAINTENANCE_MARGIN_BPS = 300;
    uint16 internal constant TRADING_FEE_BPS = 5;
    uint32 internal constant MAX_LEVERAGE_BPS = 200_000;
    uint256 internal constant EURC_OI_CAP = 1_000e6;
    uint256 internal constant TEST_FIAT_OI_CAP = 500e6;
    uint256 internal constant TEST_CRYPTO_OI_CAP = 250e6;
    uint256 internal constant DEFAULT_MIN_PROTOCOL_LIQUIDITY = 100e6;

    uint256 internal constant MAX_FUNDING_RATE_BPS_PER_SECOND = 1;
    uint256 internal constant FUNDING_VELOCITY_BPS = 1;
    uint16 internal constant LIQUIDATION_BOUNTY_BPS = 500;
    uint256 internal constant LIQUIDATION_BOUNTY_CAP = 5e6;
    uint256 internal constant MIN_LIQUIDATION_FLAG_DELAY = 60;
    uint256 internal constant LIQUIDATION_FLAG_DELAY = 120;

    struct Stack {
        FxPerpClearinghouse clearinghouse;
        FxMarginAccount margin;
        FxFundingEngine funding;
        FxHealthChecker health;
        FxLiquidationEngine liquidation;
        FxOrderSettlement settlement;
        address admin;
        address keeper;
        address usdc;
        address oracle;
        uint256 minProtocolLiquidity;
    }

    struct MarketSpec {
        string key;
        bytes32 marketId;
        address baseToken;
        uint256 oiCap;
    }

    error WrongChain(uint256 chainId);
    error MissingCode(string label, address target);
    error AddressMismatch(string label, address actual, address expected);
    error BoolMismatch(string label, bool actual, bool expected);
    error UintMismatch(string label, uint256 actual, uint256 expected);
    error ProtocolLiquidityBelowTarget(uint256 actual, uint256 minimum);
    error UnsafeLiquidationFlagDelay(uint256 delay);

    function _readStack() internal view returns (Stack memory stack) {
        stack = Stack({
            clearinghouse: FxPerpClearinghouse(vm.envAddress("ARC_PERP_CLEARINGHOUSE")),
            margin: FxMarginAccount(vm.envAddress("ARC_PERP_MARGIN")),
            funding: FxFundingEngine(vm.envAddress("ARC_PERP_FUNDING")),
            health: FxHealthChecker(vm.envAddress("ARC_PERP_HEALTH")),
            liquidation: FxLiquidationEngine(vm.envAddress("ARC_PERP_LIQUIDATION")),
            settlement: FxOrderSettlement(vm.envAddress("ARC_PERP_SETTLEMENT")),
            admin: vm.envOr("INITIAL_ADMIN", DEFAULT_ADMIN),
            keeper: vm.envOr("KEEPER", DEFAULT_ADMIN),
            usdc: vm.envOr("ARC_USDC", DEFAULT_USDC),
            oracle: vm.envAddress("ARC_FX_ORACLE"),
            minProtocolLiquidity: vm.envOr("ARC_PERP_MIN_PROTOCOL_LIQUIDITY", DEFAULT_MIN_PROTOCOL_LIQUIDITY)
        });
    }

    function _verify(Stack memory stack) internal view {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        _expectCode("FxPerpClearinghouse", address(stack.clearinghouse));
        _expectCode("FxMarginAccount", address(stack.margin));
        _expectCode("FxFundingEngine", address(stack.funding));
        _expectCode("FxHealthChecker", address(stack.health));
        _expectCode("FxLiquidationEngine", address(stack.liquidation));
        _expectCode("FxOrderSettlement", address(stack.settlement));

        _expectAddress("clearinghouse.USDC", stack.clearinghouse.USDC(), stack.usdc);
        _expectAddress("clearinghouse.ORACLE", address(stack.clearinghouse.ORACLE()), stack.oracle);
        _expectAddress("clearinghouse.marginAccount", stack.clearinghouse.marginAccount(), address(stack.margin));
        _expectAddress("clearinghouse.fundingEngine", stack.clearinghouse.fundingEngine(), address(stack.funding));
        _expectAddress("margin.USDC", address(stack.margin.USDC()), stack.usdc);
        _expectAddress(
            "margin.fundingSettlementHook", stack.margin.fundingSettlementHook(), address(stack.clearinghouse)
        );
        _expectAddress("funding.CLEARINGHOUSE", address(stack.funding.CLEARINGHOUSE()), address(stack.clearinghouse));
        _expectAddress("funding.MARGIN", address(stack.funding.MARGIN()), address(stack.margin));
        _expectAddress("health.CLEARINGHOUSE", address(stack.health.CLEARINGHOUSE()), address(stack.clearinghouse));
        _expectAddress("health.MARGIN", address(stack.health.MARGIN()), address(stack.margin));
        _expectAddress("liquidation.HEALTH", address(stack.liquidation.HEALTH()), address(stack.health));
        _expectAddress(
            "liquidation.CLEARINGHOUSE", address(stack.liquidation.CLEARINGHOUSE()), address(stack.clearinghouse)
        );
        _expectAddress("liquidation.MARGIN", address(stack.liquidation.MARGIN()), address(stack.margin));
        _expectAddress(
            "settlement.CLEARINGHOUSE", address(stack.settlement.CLEARINGHOUSE()), address(stack.clearinghouse)
        );

        _expectBool("clearinghouse.admin", stack.clearinghouse.hasRole(bytes32(0), stack.admin), true);
        _expectBool("margin.admin", stack.margin.hasRole(bytes32(0), stack.admin), true);
        _expectBool("funding.admin", stack.funding.hasRole(bytes32(0), stack.admin), true);
        _expectBool("health.admin", stack.health.hasRole(bytes32(0), stack.admin), true);
        _expectBool("liquidation.admin", stack.liquidation.hasRole(bytes32(0), stack.admin), true);
        _expectBool("settlement.admin", stack.settlement.hasRole(bytes32(0), stack.admin), true);

        _expectBool(
            "margin.clearinghouseRole.clearinghouse",
            stack.margin.hasRole(stack.margin.CLEARINGHOUSE_ROLE(), address(stack.clearinghouse)),
            true
        );
        _expectBool(
            "margin.clearinghouseRole.funding",
            stack.margin.hasRole(stack.margin.CLEARINGHOUSE_ROLE(), address(stack.funding)),
            true
        );
        _expectBool(
            "margin.clearinghouseRole.liquidation",
            stack.margin.hasRole(stack.margin.CLEARINGHOUSE_ROLE(), address(stack.liquidation)),
            true
        );
        _expectBool(
            "margin.accountOperator.keeper",
            stack.margin.hasRole(stack.margin.ACCOUNT_OPERATOR_ROLE(), stack.keeper),
            true
        );
        _expectBool(
            "clearinghouse.orderSettlementRole",
            stack.clearinghouse.hasRole(stack.clearinghouse.ORDER_SETTLEMENT_ROLE(), address(stack.settlement)),
            true
        );
        _expectBool(
            "clearinghouse.liquidationEngineRole",
            stack.clearinghouse.hasRole(stack.clearinghouse.LIQUIDATION_ENGINE_ROLE(), address(stack.liquidation)),
            true
        );
        _expectBool(
            "clearinghouse.executor.keeper",
            stack.clearinghouse.hasRole(stack.clearinghouse.EXECUTOR_ROLE(), stack.keeper),
            true
        );
        _expectBool(
            "settlement.settler.keeper", stack.settlement.hasRole(stack.settlement.SETTLER_ROLE(), stack.keeper), true
        );

        _verifyMarket(stack, _marketSpec("EURC_USDC", "EURC", EURC, EURC_OI_CAP));
        _verifyMarket(stack, _marketSpec("TJPYC_USDC", "tJPYC", TJPYC, TEST_FIAT_OI_CAP));
        _verifyMarket(stack, _marketSpec("TMXNB_USDC", "tMXNB", TMXNB, TEST_FIAT_OI_CAP));
        _verifyMarket(stack, _marketSpec("CIRBTC_USDC", "cirBTC", CIRBTC, TEST_CRYPTO_OI_CAP));

        _validateLiquidationDelay();
        (uint16 bountyBps, uint256 bountyCap, uint256 flagDelay) = stack.liquidation.liquidationConfig();
        _expectUint("liquidation.bountyBps", bountyBps, LIQUIDATION_BOUNTY_BPS);
        _expectUint("liquidation.bountyCap", bountyCap, LIQUIDATION_BOUNTY_CAP);
        _expectUint("liquidation.flagDelay", flagDelay, LIQUIDATION_FLAG_DELAY);
        if (flagDelay < MIN_LIQUIDATION_FLAG_DELAY) revert UnsafeLiquidationFlagDelay(flagDelay);

        uint256 protocolLiquidity = stack.margin.protocolLiquidity();
        if (protocolLiquidity < stack.minProtocolLiquidity) {
            revert ProtocolLiquidityBelowTarget(protocolLiquidity, stack.minProtocolLiquidity);
        }
    }

    function _verifyMarket(Stack memory stack, MarketSpec memory spec) internal view {
        IFxPerpClearinghouse.MarketConfig memory market = stack.clearinghouse.marketConfig(spec.marketId);
        _expectAddress(string.concat(spec.key, ".baseToken"), market.baseToken, spec.baseToken);
        _expectBool(string.concat(spec.key, ".enabled"), market.enabled, true);
        _expectUint(string.concat(spec.key, ".initialMarginBps"), market.initialMarginBps, INITIAL_MARGIN_BPS);
        _expectUint(
            string.concat(spec.key, ".maintenanceMarginBps"), market.maintenanceMarginBps, MAINTENANCE_MARGIN_BPS
        );
        _expectUint(string.concat(spec.key, ".tradingFeeBps"), market.tradingFeeBps, TRADING_FEE_BPS);
        _expectUint(string.concat(spec.key, ".maxLeverageBps"), market.maxLeverageBps, MAX_LEVERAGE_BPS);
        _expectUint(string.concat(spec.key, ".maxOpenInterestUsd"), market.maxOpenInterestUsd, spec.oiCap);
        _expectUint(string.concat(spec.key, ".maxSkewUsd"), market.maxSkewUsd, spec.oiCap);

        (bool fundingEnabled, uint256 maxRate, uint256 velocity) = stack.funding.fundingConfig(spec.marketId);
        _expectBool(string.concat(spec.key, ".funding.enabled"), fundingEnabled, true);
        _expectUint(string.concat(spec.key, ".funding.maxRate"), maxRate, MAX_FUNDING_RATE_BPS_PER_SECOND);
        _expectUint(string.concat(spec.key, ".funding.velocity"), velocity, FUNDING_VELOCITY_BPS);
    }

    function _writeManifest(string memory path, Stack memory stack) internal {
        string memory root = "arcPerpConfig";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "exportedBlockNumber", block.number);
        vm.serializeUint(root, "exportedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "admin", stack.admin);
        vm.serializeAddress(root, "keeper", stack.keeper);
        vm.serializeAddress(root, "USDC", stack.usdc);
        vm.serializeAddress(root, "FxOracle", stack.oracle);
        vm.serializeAddress(root, "FxPerpClearinghouse", address(stack.clearinghouse));
        vm.serializeAddress(root, "FxMarginAccount", address(stack.margin));
        vm.serializeAddress(root, "FxFundingEngine", address(stack.funding));
        vm.serializeAddress(root, "FxHealthChecker", address(stack.health));
        vm.serializeAddress(root, "FxLiquidationEngine", address(stack.liquidation));
        vm.serializeAddress(root, "FxOrderSettlement", address(stack.settlement));
        vm.serializeAddress(root, "clearinghouse_fundingEngine", stack.clearinghouse.fundingEngine());
        vm.serializeAddress(root, "margin_fundingSettlementHook", stack.margin.fundingSettlementHook());
        vm.serializeUint(root, "protocolLiquidity", stack.margin.protocolLiquidity());
        vm.serializeUint(root, "totalAccountMargin", stack.margin.totalAccountMargin());
        vm.serializeUint(root, "marginUsdcBalance", IERC20(stack.usdc).balanceOf(address(stack.margin)));
        vm.serializeUint(root, "minProtocolLiquidity", stack.minProtocolLiquidity);

        _serializeMarket(root, stack, _marketSpec("EURC_USDC", "EURC", EURC, EURC_OI_CAP));
        _serializeMarket(root, stack, _marketSpec("TJPYC_USDC", "tJPYC", TJPYC, TEST_FIAT_OI_CAP));
        _serializeMarket(root, stack, _marketSpec("TMXNB_USDC", "tMXNB", TMXNB, TEST_FIAT_OI_CAP));
        _serializeMarket(root, stack, _marketSpec("CIRBTC_USDC", "cirBTC", CIRBTC, TEST_CRYPTO_OI_CAP));

        (uint16 bountyBps, uint256 bountyCap, uint256 flagDelay) = stack.liquidation.liquidationConfig();
        vm.serializeUint(root, "liquidation_bountyBps", bountyBps);
        vm.serializeUint(root, "liquidation_bountyCap", bountyCap);
        vm.serializeUint(root, "liquidation_flagDelay", flagDelay);
        vm.serializeBool(root, "role_clearinghouse_admin", stack.clearinghouse.hasRole(bytes32(0), stack.admin));
        vm.serializeBool(root, "role_margin_admin", stack.margin.hasRole(bytes32(0), stack.admin));
        vm.serializeBool(root, "role_funding_admin", stack.funding.hasRole(bytes32(0), stack.admin));
        vm.serializeBool(root, "role_health_admin", stack.health.hasRole(bytes32(0), stack.admin));
        vm.serializeBool(root, "role_liquidation_admin", stack.liquidation.hasRole(bytes32(0), stack.admin));
        vm.serializeBool(root, "role_settlement_admin", stack.settlement.hasRole(bytes32(0), stack.admin));
        vm.serializeBool(
            root,
            "role_margin_clearinghouse",
            stack.margin.hasRole(stack.margin.CLEARINGHOUSE_ROLE(), address(stack.clearinghouse))
        );
        vm.serializeBool(
            root, "role_margin_funding", stack.margin.hasRole(stack.margin.CLEARINGHOUSE_ROLE(), address(stack.funding))
        );
        vm.serializeBool(
            root,
            "role_margin_liquidation",
            stack.margin.hasRole(stack.margin.CLEARINGHOUSE_ROLE(), address(stack.liquidation))
        );
        vm.serializeBool(
            root,
            "role_margin_accountOperatorKeeper",
            stack.margin.hasRole(stack.margin.ACCOUNT_OPERATOR_ROLE(), stack.keeper)
        );
        vm.serializeBool(
            root,
            "role_clearinghouse_orderSettlement",
            stack.clearinghouse.hasRole(stack.clearinghouse.ORDER_SETTLEMENT_ROLE(), address(stack.settlement))
        );
        vm.serializeBool(
            root,
            "role_clearinghouse_liquidationEngine",
            stack.clearinghouse.hasRole(stack.clearinghouse.LIQUIDATION_ENGINE_ROLE(), address(stack.liquidation))
        );
        vm.serializeBool(
            root,
            "role_clearinghouse_executorKeeper",
            stack.clearinghouse.hasRole(stack.clearinghouse.EXECUTOR_ROLE(), stack.keeper)
        );
        string memory json = vm.serializeBool(
            root,
            "role_settlement_settlerKeeper",
            stack.settlement.hasRole(stack.settlement.SETTLER_ROLE(), stack.keeper)
        );
        vm.writeJson(json, path);
    }

    function _serializeMarket(string memory root, Stack memory stack, MarketSpec memory spec) internal {
        IFxPerpClearinghouse.MarketConfig memory market = stack.clearinghouse.marketConfig(spec.marketId);
        string memory prefix = spec.key;
        vm.serializeString(root, string.concat(prefix, "_marketId"), vm.toString(spec.marketId));
        vm.serializeAddress(root, string.concat(prefix, "_baseToken"), market.baseToken);
        vm.serializeBool(root, string.concat(prefix, "_enabled"), market.enabled);
        vm.serializeUint(root, string.concat(prefix, "_initialMarginBps"), market.initialMarginBps);
        vm.serializeUint(root, string.concat(prefix, "_maintenanceMarginBps"), market.maintenanceMarginBps);
        vm.serializeUint(root, string.concat(prefix, "_tradingFeeBps"), market.tradingFeeBps);
        vm.serializeUint(root, string.concat(prefix, "_maxLeverageBps"), market.maxLeverageBps);
        vm.serializeUint(root, string.concat(prefix, "_maxOpenInterestUsd"), market.maxOpenInterestUsd);
        vm.serializeUint(root, string.concat(prefix, "_maxSkewUsd"), market.maxSkewUsd);
        vm.serializeUint(
            root, string.concat(prefix, "_openInterestLong"), stack.clearinghouse.openInterestLong(spec.marketId)
        );
        vm.serializeUint(
            root, string.concat(prefix, "_openInterestShort"), stack.clearinghouse.openInterestShort(spec.marketId)
        );

        (bool fundingEnabled, uint256 maxRate, uint256 velocity) = stack.funding.fundingConfig(spec.marketId);
        vm.serializeBool(root, string.concat(prefix, "_fundingEnabled"), fundingEnabled);
        vm.serializeUint(root, string.concat(prefix, "_maxFundingRateBpsPerSecond"), maxRate);
        vm.serializeUint(root, string.concat(prefix, "_fundingVelocityBps"), velocity);
    }

    function _marketSpec(string memory key, string memory symbol, address baseToken, uint256 oiCap)
        internal
        pure
        returns (MarketSpec memory spec)
    {
        spec = MarketSpec({
            key: key,
            marketId: keccak256(bytes(string.concat("FX-PERP:", symbol, "/USDC"))),
            baseToken: baseToken,
            oiCap: oiCap
        });
    }

    function _expectCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert MissingCode(label, target);
    }

    function _expectAddress(string memory label, address actual, address expected) internal pure {
        if (actual != expected) revert AddressMismatch(label, actual, expected);
    }

    function _expectBool(string memory label, bool actual, bool expected) internal pure {
        if (actual != expected) revert BoolMismatch(label, actual, expected);
    }

    function _expectUint(string memory label, uint256 actual, uint256 expected) internal pure {
        if (actual != expected) revert UintMismatch(label, actual, expected);
    }

    function _validateLiquidationDelay() internal pure {
        if (LIQUIDATION_FLAG_DELAY < MIN_LIQUIDATION_FLAG_DELAY) {
            revert UnsafeLiquidationFlagDelay(LIQUIDATION_FLAG_DELAY);
        }
    }

    function _contractAddressesJson(Stack memory stack) internal view returns (string memory) {
        return string.concat(
            "{\"",
            vm.toString(block.chainid),
            "\":{\"FxPerpClearinghouse\":\"",
            vm.toString(address(stack.clearinghouse)),
            "\",\"FxMarginAccount\":\"",
            vm.toString(address(stack.margin)),
            "\",\"FxFundingEngine\":\"",
            vm.toString(address(stack.funding)),
            "\",\"FxHealthChecker\":\"",
            vm.toString(address(stack.health)),
            "\",\"FxLiquidationEngine\":\"",
            vm.toString(address(stack.liquidation)),
            "\",\"FxOrderSettlement\":\"",
            vm.toString(address(stack.settlement)),
            "\"}}"
        );
    }
}

contract VerifyArcPerpConfig is ArcPerpConfigReadinessBase {
    function run() external view {
        Stack memory stack = _readStack();
        _verify(stack);
        console2.log("Arc Phase B-E perp config verified");
        console2.log("chainId              ", block.chainid);
        console2.log("protocolLiquidity    ", stack.margin.protocolLiquidity());
        console2.log("margin USDC balance  ", IERC20(stack.usdc).balanceOf(address(stack.margin)));
    }
}

contract ExportArcPerpConfig is ArcPerpConfigReadinessBase {
    function run() external {
        Stack memory stack = _readStack();
        _verify(stack);

        string memory defaultPath = string.concat("../deployments/perps-config-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("ARC_PERP_CONFIG_PATH", defaultPath);
        _writeManifest(path, stack);

        console2.log("Arc Phase B-E perp config exported");
        console2.log("path                 ", path);
        console2.log("protocolLiquidity    ", stack.margin.protocolLiquidity());
        console2.log("margin USDC balance  ", IERC20(stack.usdc).balanceOf(address(stack.margin)));
        console2.log("CONTRACT_ADDRESSES_JSON:");
        console2.log(_contractAddressesJson(stack));
    }
}
