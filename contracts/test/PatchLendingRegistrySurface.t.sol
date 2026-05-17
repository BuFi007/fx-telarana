// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxTimelock} from "../src/governance/FxTimelock.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice Local rehearsal for the lending registry surface migration.
///         Proves the shape required by the backend before a live broadcast:
///         listPools, isPoolLive, AccessControl, Pausable, and immutable
///         consumer rebinding all work against existing MarketParams.
contract PatchLendingRegistrySurfaceTest is Test {
    address internal deployer = address(0xD0EE);
    address internal relayer = address(0xB0F1);
    address internal morpho = address(0xBBBB);
    address internal oracle = address(0x0A0C1E);
    address internal irm = address(0x1E11);
    address internal usdc = address(0x1000);
    address internal eurc = address(0x2000);
    address internal adapterM1 = address(0xA001);
    address internal adapterM2 = address(0xA002);
    address internal cctpMessageTransmitter = address(0xCC7F);

    uint256 internal constant LLTV = 0.86e18;

    function test_patchShapeRegistersExistingMarketsAndRebindsConsumers() public {
        vm.startPrank(deployer);

        FxMarketRegistry registry = new FxMarketRegistry(morpho, deployer);

        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: eurc,
            collateralToken: usdc,
            oracle: adapterM1,
            irm: irm,
            lltv: LLTV
        });
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: usdc,
            collateralToken: eurc,
            oracle: adapterM2,
            irm: irm,
            lltv: LLTV
        });

        bytes32 m1Id = registry.registerMarket(m1);
        bytes32 m2Id = registry.registerMarket(m2);

        FxLiquidator liquidator = new FxLiquidator(morpho, address(registry), oracle, deployer);
        FxHubMessageReceiver receiver =
            new FxHubMessageReceiver(cctpMessageTransmitter, usdc, address(registry), deployer);
        receiver.setRelayCaller(relayer, true);

        FxTimelock timelock = _deployTimelockAndHandoff(registry, liquidator);

        vm.stopPrank();

        IFxMarketRegistry.MarketParams[] memory pools = registry.listPools();
        assertEq(pools.length, 2, "pool count");
        assertEq(pools[0].loanToken, eurc, "m1 loan");
        assertEq(pools[0].collateralToken, usdc, "m1 collateral");
        assertEq(pools[1].loanToken, usdc, "m2 loan");
        assertEq(pools[1].collateralToken, eurc, "m2 collateral");
        assertEq(registry.marketIdOf(eurc, usdc), m1Id, "m1 id");
        assertEq(registry.marketIdOf(usdc, eurc), m2Id, "m2 id");
        assertTrue(registry.isPoolLive(eurc, usdc), "m1 live");
        assertTrue(registry.isPoolLive(usdc, eurc), "m2 live");
        assertFalse(registry.paused(), "registry paused");

        assertEq(address(liquidator.REGISTRY()), address(registry), "liquidator registry");
        assertEq(receiver.MARKET_REGISTRY(), address(registry), "receiver registry");
        assertTrue(receiver.relayCallers(relayer), "relay caller");

        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock)), "registry timelock admin");
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "registry deployer admin");
        assertTrue(liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), address(timelock)), "liq timelock admin");
        assertFalse(liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer), "liq deployer admin");
        assertTrue(registry.hasRole(registry.OPERATIONS_ROLE(), deployer), "registry deployer ops");
        assertTrue(liquidator.hasRole(liquidator.OPERATIONS_ROLE(), deployer), "liq deployer ops");
    }

    function _deployTimelockAndHandoff(
        FxMarketRegistry registry,
        FxLiquidator liquidator
    ) internal returns (FxTimelock timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        timelock = new FxTimelock(24 hours, proposers, executors, address(0));

        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock));
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        liquidator.grantRole(liquidator.DEFAULT_ADMIN_ROLE(), address(timelock));
        liquidator.renounceRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
