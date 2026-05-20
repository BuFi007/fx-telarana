// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";
import {FxHealthChecker} from "../src/perp/FxHealthChecker.sol";
import {FxLiquidationEngine} from "../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../src/perp/FxMarginAccount.sol";
import {FxOrderSettlement} from "../src/perp/FxOrderSettlement.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";

interface ISprint1FxOracle {
    function MAX_ORACLE_AGE_HARD_CAP() external view returns (uint256);
    function MAX_DEVIATION_BPS_HARD_CAP() external view returns (uint256);
    function MAX_CONFIDENCE_BPS_HARD_CAP() external view returns (uint256);
    function config() external view returns (uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps);
}

/// @notice Deploys the addressable Phase B-E perp stack and applies the
///         shared safe liquidation defaults. Per-market risk params remain a
///         separate explicit configure transaction.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   USDC
///   FX_ORACLE — MUST be a sprint-1 FxOracle or this script refuses to deploy.
///
/// Optional env:
///   INITIAL_ADMIN — defaults to deployer and must equal deployer for this
///                   bootstrap script. Handoff happens after configure/export.
///   KEEPER        — defaults to deployer; receives keeper execution roles
///   PERP_DEPLOYMENT_PATH — defaults to ../deployments/perps-<chainid>.json
///
/// Post-deploy wiring:
///   1. Configure market params with FxPerpClearinghouse.configureMarket.
///   2. Configure funding params with FxFundingEngine.configureFunding.
///   3. Seed FxMarginAccount protocol liquidity before opening unmatched positions.
///   4. Export the chain config manifest after market/funding/liquidation params are live.
///   5. Inject the printed CONTRACT_ADDRESSES_JSON into BUFX/perps backend env.
contract DeployFxPerpStack is Script {
    uint256 internal constant MAX_ORACLE_AGE_HARD_CAP = 30 minutes;
    uint256 internal constant MAX_DEVIATION_BPS_HARD_CAP = 500;
    uint256 internal constant MAX_CONFIDENCE_BPS_HARD_CAP = 500;
    uint16 internal constant LIQUIDATION_BOUNTY_BPS = 500;
    uint256 internal constant LIQUIDATION_BOUNTY_CAP = 5e6;
    uint256 internal constant LIQUIDATION_FLAG_DELAY = 120;
    uint256 internal constant MIN_LIQUIDATION_FLAG_DELAY = 60;

    error OracleMissingCode(address oracle);
    error OracleMissingSprint1Selectors(address oracle);
    error OracleHardCapMismatch(address oracle, string selectorName, uint256 actual, uint256 expected);
    error OracleConfigOutsideSprint1Caps(address oracle, uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps);
    error UnsafeLiquidationFlagDelay(uint256 delay);
    error BootstrapAdminMustBeDeployer(address deployer, address initialAdmin);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC");
        address oracle = vm.envAddress("FX_ORACLE");
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);
        address keeper = vm.envOr("KEEPER", deployer);

        string memory defaultPath = string.concat("../deployments/perps-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("PERP_DEPLOYMENT_PATH", defaultPath);

        console2.log("============================================");
        console2.log("Deploying Fx Phase B-E perp stack");
        console2.log("============================================");
        console2.log("chainId       ", block.chainid);
        console2.log("deployer      ", deployer);
        console2.log("usdc          ", usdc);
        console2.log("oracle        ", oracle);
        console2.log("initialAdmin  ", initialAdmin);
        console2.log("keeper        ", keeper);
        console2.log("flagDelay     ", LIQUIDATION_FLAG_DELAY);

        _verifySprint1Oracle(oracle);
        _validateLiquidationDelay();
        _validateBootstrapAdmin(deployer, initialAdmin);

        vm.startBroadcast(pk);
        FxMarginAccount margin = new FxMarginAccount(usdc, initialAdmin);
        FxPerpClearinghouse clearinghouse = new FxPerpClearinghouse(usdc, oracle, address(margin), initialAdmin);
        FxFundingEngine funding = new FxFundingEngine(address(clearinghouse), address(margin), initialAdmin);
        FxHealthChecker health = new FxHealthChecker(address(clearinghouse), address(margin), initialAdmin);
        FxLiquidationEngine liquidation =
            new FxLiquidationEngine(address(health), address(clearinghouse), address(margin), initialAdmin);
        FxOrderSettlement settlement = new FxOrderSettlement(address(clearinghouse), initialAdmin);

        clearinghouse.setFundingEngine(address(funding));
        margin.setFundingSettlementHook(address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(funding));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(liquidation));
        margin.grantRole(margin.ACCOUNT_OPERATOR_ROLE(), keeper);
        clearinghouse.grantRole(clearinghouse.ORDER_SETTLEMENT_ROLE(), address(settlement));
        clearinghouse.grantRole(clearinghouse.LIQUIDATION_ENGINE_ROLE(), address(liquidation));
        clearinghouse.grantRole(clearinghouse.EXECUTOR_ROLE(), keeper);
        settlement.grantRole(settlement.SETTLER_ROLE(), keeper);
        liquidation.configureLiquidation(
            FxLiquidationEngine.LiquidationConfig({
                bountyBps: LIQUIDATION_BOUNTY_BPS, bountyCap: LIQUIDATION_BOUNTY_CAP, flagDelay: LIQUIDATION_FLAG_DELAY
            })
        );
        vm.stopBroadcast();

        _writeManifest(
            path,
            deployer,
            keeper,
            address(margin),
            address(clearinghouse),
            address(funding),
            address(health),
            address(liquidation),
            address(settlement),
            LIQUIDATION_FLAG_DELAY
        );

        console2.log("============================================");
        console2.log("FxMarginAccount       ", address(margin));
        console2.log("FxPerpClearinghouse   ", address(clearinghouse));
        console2.log("FxFundingEngine       ", address(funding));
        console2.log("FxHealthChecker       ", address(health));
        console2.log("FxLiquidationEngine   ", address(liquidation));
        console2.log("FxOrderSettlement     ", address(settlement));
        console2.log("Liquidation flagDelay ", LIQUIDATION_FLAG_DELAY);
        console2.log("manifest              ", path);
        console2.log("============================================");
        console2.log("CONTRACT_ADDRESSES_JSON:");
        console2.log(
            _contractAddressesJson(
                address(margin),
                address(clearinghouse),
                address(funding),
                address(health),
                address(liquidation),
                address(settlement)
            )
        );
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Run dry-run first; do not broadcast until user approves.");
        console2.log("  2. Configure market/funding risk params from explicit user choices.");
        console2.log("  3. Seed protocol liquidity in FxMarginAccount before unmatched testnet opens.");
        console2.log("  4. Export the config manifest and inject the six addresses into CONTRACT_ADDRESSES_JSON.");
    }

    function _verifySprint1Oracle(address oracle) internal view {
        if (oracle.code.length == 0) revert OracleMissingCode(oracle);

        ISprint1FxOracle fxOracle = ISprint1FxOracle(oracle);
        uint256 maxAgeHardCap;
        uint256 maxDeviationHardCap;
        uint256 maxConfidenceHardCap;

        try fxOracle.MAX_ORACLE_AGE_HARD_CAP() returns (uint256 value) {
            maxAgeHardCap = value;
        } catch {
            revert OracleMissingSprint1Selectors(oracle);
        }
        try fxOracle.MAX_DEVIATION_BPS_HARD_CAP() returns (uint256 value) {
            maxDeviationHardCap = value;
        } catch {
            revert OracleMissingSprint1Selectors(oracle);
        }
        try fxOracle.MAX_CONFIDENCE_BPS_HARD_CAP() returns (uint256 value) {
            maxConfidenceHardCap = value;
        } catch {
            revert OracleMissingSprint1Selectors(oracle);
        }

        if (maxAgeHardCap != MAX_ORACLE_AGE_HARD_CAP) {
            revert OracleHardCapMismatch(oracle, "MAX_ORACLE_AGE_HARD_CAP", maxAgeHardCap, MAX_ORACLE_AGE_HARD_CAP);
        }
        if (maxDeviationHardCap != MAX_DEVIATION_BPS_HARD_CAP) {
            revert OracleHardCapMismatch(
                oracle, "MAX_DEVIATION_BPS_HARD_CAP", maxDeviationHardCap, MAX_DEVIATION_BPS_HARD_CAP
            );
        }
        if (maxConfidenceHardCap != MAX_CONFIDENCE_BPS_HARD_CAP) {
            revert OracleHardCapMismatch(
                oracle, "MAX_CONFIDENCE_BPS_HARD_CAP", maxConfidenceHardCap, MAX_CONFIDENCE_BPS_HARD_CAP
            );
        }

        try fxOracle.config() returns (uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps) {
            if (
                maxAge == 0 || maxAge > MAX_ORACLE_AGE_HARD_CAP || maxDevBps == 0
                    || maxDevBps > MAX_DEVIATION_BPS_HARD_CAP || maxConfBps == 0
                    || maxConfBps > MAX_CONFIDENCE_BPS_HARD_CAP
            ) {
                revert OracleConfigOutsideSprint1Caps(oracle, maxAge, maxDevBps, maxConfBps);
            }
        } catch {
            revert OracleMissingSprint1Selectors(oracle);
        }
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address keeper,
        address margin,
        address clearinghouse,
        address funding,
        address health,
        address liquidation,
        address settlement,
        uint256 liquidationFlagDelay
    ) internal {
        string memory root = "perp";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "keeper", keeper);
        vm.serializeAddress(root, "FxMarginAccount", margin);
        vm.serializeAddress(root, "FxPerpClearinghouse", clearinghouse);
        vm.serializeAddress(root, "FxFundingEngine", funding);
        vm.serializeAddress(root, "FxHealthChecker", health);
        vm.serializeAddress(root, "FxLiquidationEngine", liquidation);
        vm.serializeAddress(root, "FxOrderSettlement", settlement);
        vm.serializeUint(root, "liquidation_bountyBps", LIQUIDATION_BOUNTY_BPS);
        vm.serializeUint(root, "liquidation_bountyCap", LIQUIDATION_BOUNTY_CAP);
        string memory json = vm.serializeUint(root, "liquidation_flagDelay", liquidationFlagDelay);
        vm.writeJson(json, path);
    }

    function _validateLiquidationDelay() internal pure {
        if (LIQUIDATION_FLAG_DELAY < MIN_LIQUIDATION_FLAG_DELAY) {
            revert UnsafeLiquidationFlagDelay(LIQUIDATION_FLAG_DELAY);
        }
    }

    function _validateBootstrapAdmin(address deployer, address initialAdmin) internal pure {
        if (initialAdmin != deployer) revert BootstrapAdminMustBeDeployer(deployer, initialAdmin);
    }

    function _contractAddressesJson(
        address margin,
        address clearinghouse,
        address funding,
        address health,
        address liquidation,
        address settlement
    ) internal view returns (string memory) {
        return string.concat(
            "{\"",
            vm.toString(block.chainid),
            "\":{\"FxPerpClearinghouse\":\"",
            vm.toString(clearinghouse),
            "\",\"FxMarginAccount\":\"",
            vm.toString(margin),
            "\",\"FxFundingEngine\":\"",
            vm.toString(funding),
            "\",\"FxHealthChecker\":\"",
            vm.toString(health),
            "\",\"FxLiquidationEngine\":\"",
            vm.toString(liquidation),
            "\",\"FxOrderSettlement\":\"",
            vm.toString(settlement),
            "\"}}"
        );
    }
}
