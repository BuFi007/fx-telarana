// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxFundingEngine} from "../src/perp/FxFundingEngine.sol";
import {FxHealthChecker} from "../src/perp/FxHealthChecker.sol";
import {FxLiquidationEngine} from "../src/perp/FxLiquidationEngine.sol";
import {FxMarginAccount} from "../src/perp/FxMarginAccount.sol";
import {FxOrderSettlement} from "../src/perp/FxOrderSettlement.sol";
import {FxPerpClearinghouse} from "../src/perp/FxPerpClearinghouse.sol";

/// @notice Deploys the addressable Phase B-E perp stack without configuring
///         production market risk. Market risk params are intentionally a
///         separate admin transaction so they are not silently invented here.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   USDC
///   FX_ORACLE
///
/// Optional env:
///   INITIAL_ADMIN — defaults to deployer
///   KEEPER        — defaults to deployer; receives keeper execution roles
///   PERP_DEPLOYMENT_PATH — defaults to deployments/perps-<chainid>.json
///
/// Post-deploy wiring:
///   1. Configure market params with FxPerpClearinghouse.configureMarket.
///   2. Configure funding params with FxFundingEngine.configureFunding.
///   3. Configure liquidation params with FxLiquidationEngine.configureLiquidation.
///   4. Seed FxMarginAccount protocol liquidity before opening unmatched positions.
///   5. Export the Arc config manifest after market/funding/liquidation params are live.
///   6. Inject the printed CONTRACT_ADDRESSES_JSON into BUFX/perps backend env.
contract DeployFxPerpStack is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC");
        address oracle = vm.envAddress("FX_ORACLE");
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);
        address keeper = vm.envOr("KEEPER", deployer);

        string memory defaultPath = string.concat("deployments/perps-", vm.toString(block.chainid), ".json");
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
            address(settlement)
        );

        console2.log("============================================");
        console2.log("FxMarginAccount       ", address(margin));
        console2.log("FxPerpClearinghouse   ", address(clearinghouse));
        console2.log("FxFundingEngine       ", address(funding));
        console2.log("FxHealthChecker       ", address(health));
        console2.log("FxLiquidationEngine   ", address(liquidation));
        console2.log("FxOrderSettlement     ", address(settlement));
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
        console2.log("  2. Configure market/funding/liquidation risk params from explicit user choices.");
        console2.log("  3. Seed protocol liquidity in FxMarginAccount before unmatched testnet opens.");
        console2.log("  4. Export the config manifest and inject the six addresses into CONTRACT_ADDRESSES_JSON.");
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
        address settlement
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
        string memory json = vm.serializeAddress(root, "FxOrderSettlement", settlement);
        vm.writeJson(json, path);
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
