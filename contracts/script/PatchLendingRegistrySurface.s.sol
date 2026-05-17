// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxTimelock} from "../src/governance/FxTimelock.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice Patch an already-live lending hub from the legacy owner-based
///         registry surface to the current AccessControl/Pausable/listPools
///         surface without recreating Morpho markets.
///
/// This script intentionally calls `registerMarket`, not
/// `createAndRegisterMarket`: the markets already exist on Morpho. The patch
/// deploys a new registry with the current ABI, registers the existing market
/// params, then redeploys the immutable consumers that must point at that
/// registry: `FxLiquidator` and `FxHubMessageReceiver`.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   FXT_PATCH_MORPHO
///   FXT_PATCH_ORACLE
///   FXT_PATCH_IRM
///   FXT_PATCH_LLTV
///   FXT_PATCH_USDC
///   FXT_PATCH_CCTP_MESSAGE_TRANSMITTER
///   FXT_PATCH_M1_LOAN
///   FXT_PATCH_M1_COLLATERAL
///   FXT_PATCH_M1_ORACLE_ADAPTER
///   FXT_PATCH_M2_LOAN
///   FXT_PATCH_M2_COLLATERAL
///   FXT_PATCH_M2_ORACLE_ADAPTER
///
/// Optional env:
///   FXT_PATCH_GATEWAY_HOOK      set on the new receiver before ownership
///                               handoff; omit to leave unset
///   FXT_PATCH_RELAY_CALLER      allowlist one relayer before ownership
///                               handoff; omit for none
///   FXT_PATCH_TIMELOCK_DELAY    default 24 hours
///   FXT_PATCH_RECEIVER_OWNER    default deployer; set to a multisig if
///                               immediate receiver owner rotation is intended
///   FXT_PATCH_RECEIVER_OWNER_IS_TIMELOCK
///                               default false; when true, transfers receiver
///                               ownership to the freshly deployed timelock
contract PatchLendingRegistrySurface is Script {
    struct MarketPatch {
        address loanToken;
        address collateralToken;
        address oracleAdapter;
    }

    struct PatchConfig {
        address deployer;
        address morpho;
        address oracle;
        address irm;
        uint256 lltv;
        address usdc;
        address cctpMessageTransmitter;
        address gatewayHook;
        address relayCaller;
        uint256 timelockDelay;
        address receiverOwner;
        bool receiverOwnerIsTimelock;
        MarketPatch m1;
        MarketPatch m2;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        PatchConfig memory c = _readConfig(vm.addr(pk));

        console2.log("======== fx-Telarana lending registry surface patch ========");
        console2.log("deployer       ", c.deployer);
        console2.log("morpho         ", c.morpho);
        console2.log("oracle         ", c.oracle);
        console2.log("irm            ", c.irm);
        console2.log("usdc           ", c.usdc);
        console2.log("cctp mt        ", c.cctpMessageTransmitter);
        console2.log("gateway hook   ", c.gatewayHook);
        console2.log("receiver owner ", c.receiverOwner);

        vm.startBroadcast(pk);

        FxMarketRegistry registry = new FxMarketRegistry(c.morpho, c.deployer);
        bytes32 m1Id = _registerExistingMarket(registry, c.m1, c.irm, c.lltv);
        bytes32 m2Id = _registerExistingMarket(registry, c.m2, c.irm, c.lltv);

        FxLiquidator liquidator = new FxLiquidator(c.morpho, address(registry), c.oracle, c.deployer);
        FxHubMessageReceiver receiver =
            new FxHubMessageReceiver(c.cctpMessageTransmitter, c.usdc, address(registry), c.deployer);

        if (c.gatewayHook != address(0)) {
            receiver.setGatewayHook(c.gatewayHook);
        }
        if (c.relayCaller != address(0)) {
            receiver.setRelayCaller(c.relayCaller, true);
        }

        FxTimelock timelock = _deployTimelockAndHandoff(c.deployer, c.timelockDelay, registry, liquidator);
        address finalReceiverOwner = c.receiverOwnerIsTimelock ? address(timelock) : c.receiverOwner;
        if (finalReceiverOwner != c.deployer) {
            receiver.transferOwnership(finalReceiverOwner);
        }

        vm.stopBroadcast();

        _assertRegistrySurface(registry, c, m1Id, m2Id);
        _assertHandoff(address(timelock), c.deployer, registry, liquidator);
        require(receiver.MARKET_REGISTRY() == address(registry), "patch: receiver registry mismatch");
        require(address(liquidator.REGISTRY()) == address(registry), "patch: liquidator registry mismatch");

        console2.log("======== patched contracts ========");
        console2.log("FxMarketRegistry      ", address(registry));
        console2.log("FxLiquidator          ", address(liquidator));
        console2.log("FxHubMessageReceiver  ", address(receiver));
        console2.log("FxTimelock            ", address(timelock));
        console2.log("Market M1 id");
        console2.logBytes32(m1Id);
        console2.log("Market M2 id");
        console2.logBytes32(m2Id);
    }

    function _readConfig(address deployer) internal view returns (PatchConfig memory c) {
        c.deployer = deployer;
        c.morpho = vm.envAddress("FXT_PATCH_MORPHO");
        c.oracle = vm.envAddress("FXT_PATCH_ORACLE");
        c.irm = vm.envAddress("FXT_PATCH_IRM");
        c.lltv = vm.envUint("FXT_PATCH_LLTV");
        c.usdc = vm.envAddress("FXT_PATCH_USDC");
        c.cctpMessageTransmitter = vm.envAddress("FXT_PATCH_CCTP_MESSAGE_TRANSMITTER");
        c.gatewayHook = vm.envOr("FXT_PATCH_GATEWAY_HOOK", address(0));
        c.relayCaller = vm.envOr("FXT_PATCH_RELAY_CALLER", address(0));
        c.timelockDelay = vm.envOr("FXT_PATCH_TIMELOCK_DELAY", uint256(24 hours));
        c.receiverOwner = vm.envOr("FXT_PATCH_RECEIVER_OWNER", deployer);
        c.receiverOwnerIsTimelock = vm.envOr("FXT_PATCH_RECEIVER_OWNER_IS_TIMELOCK", false);
        c.m1 = MarketPatch({
            loanToken: vm.envAddress("FXT_PATCH_M1_LOAN"),
            collateralToken: vm.envAddress("FXT_PATCH_M1_COLLATERAL"),
            oracleAdapter: vm.envAddress("FXT_PATCH_M1_ORACLE_ADAPTER")
        });
        c.m2 = MarketPatch({
            loanToken: vm.envAddress("FXT_PATCH_M2_LOAN"),
            collateralToken: vm.envAddress("FXT_PATCH_M2_COLLATERAL"),
            oracleAdapter: vm.envAddress("FXT_PATCH_M2_ORACLE_ADAPTER")
        });
    }

    function _registerExistingMarket(
        FxMarketRegistry registry,
        MarketPatch memory market,
        address irm,
        uint256 lltv
    ) internal returns (bytes32 marketId) {
        marketId = registry.registerMarket(IFxMarketRegistry.MarketParams({
            loanToken: market.loanToken,
            collateralToken: market.collateralToken,
            oracle: market.oracleAdapter,
            irm: irm,
            lltv: lltv
        }));
    }

    function _deployTimelockAndHandoff(
        address deployer,
        uint256 minDelay,
        FxMarketRegistry registry,
        FxLiquidator liquidator
    ) internal returns (FxTimelock timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        timelock = new FxTimelock(minDelay, proposers, executors, address(0));

        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock));
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        liquidator.grantRole(liquidator.DEFAULT_ADMIN_ROLE(), address(timelock));
        liquidator.renounceRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _assertRegistrySurface(
        FxMarketRegistry registry,
        PatchConfig memory c,
        bytes32 m1Id,
        bytes32 m2Id
    ) internal view {
        IFxMarketRegistry.MarketParams[] memory pools = registry.listPools();
        require(pools.length == 2, "patch: pool count != 2");
        require(registry.marketIdOf(c.m1.loanToken, c.m1.collateralToken) == m1Id, "patch: m1 id mismatch");
        require(registry.marketIdOf(c.m2.loanToken, c.m2.collateralToken) == m2Id, "patch: m2 id mismatch");
        require(registry.isPoolLive(c.m1.loanToken, c.m1.collateralToken), "patch: m1 not live");
        require(registry.isPoolLive(c.m2.loanToken, c.m2.collateralToken), "patch: m2 not live");
        require(!registry.paused(), "patch: registry paused");
    }

    function _assertHandoff(
        address timelock,
        address deployer,
        FxMarketRegistry registry,
        FxLiquidator liquidator
    ) internal view {
        require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), timelock), "patch: registry admin != timelock");
        require(!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "patch: deployer still registry admin");
        require(liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), timelock), "patch: liq admin != timelock");
        require(!liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer), "patch: deployer still liq admin");
    }
}
