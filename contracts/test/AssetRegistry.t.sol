// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AssetRegistry} from "../src/hub/AssetRegistry.sol";

contract AssetRegistryTest is Test {
    AssetRegistry internal registry;

    address internal admin = address(0xA11CE);
    address internal outsider = address(0xBADBABE);

    address internal jpycOnArc = address(0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29);
    address internal jpycOnFuji = address(0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29);
    address internal mxnbOnArc = address(0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461);
    address internal warpRouteArc = address(0x76e90f28Ad1E3ACBd47F7a75294DCF23C598214a);
    address internal warpRouteFuji = address(0xAba718626a1521D90bE044985C0Ba6F146c8ed29);

    uint256 internal constant ARC_TESTNET = 5042002;
    uint256 internal constant FUJI = 43113;

    function setUp() public {
        registry = new AssetRegistry(admin);
    }

    // ── Tests ────────────────────────────────────────────────────────

    function test_registerAsset() public {
        vm.prank(admin);
        bytes32 key = registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);

        assertEq(key, keccak256("JPYC"));

        AssetRegistry.AssetConfig memory cfg = registry.getAsset(key);
        assertEq(cfg.symbol, "JPYC");
        assertEq(cfg.decimals, 18);
        assertEq(uint256(cfg.strategy), uint256(AssetRegistry.BridgeStrategy.Native));
        assertEq(cfg.liquidityHomeChainId, 137);
        assertTrue(cfg.enabled);

        assertEq(registry.assetCount(), 1);
    }

    function test_setChainAddress() public {
        vm.startPrank(admin);
        bytes32 key = registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);
        registry.setChainAddress(key, ARC_TESTNET, jpycOnArc);
        registry.setChainAddress(key, FUJI, jpycOnFuji);
        vm.stopPrank();

        assertEq(registry.perChainAddress(key, ARC_TESTNET), jpycOnArc);
        assertEq(registry.perChainAddress(key, FUJI), jpycOnFuji);
        assertEq(registry.tokenAddressOnChain("JPYC", ARC_TESTNET), jpycOnArc);
    }

    function test_setBridgeContract() public {
        vm.startPrank(admin);
        bytes32 key = registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);
        registry.setBridgeContract(key, ARC_TESTNET, warpRouteArc);
        registry.setBridgeContract(key, FUJI, warpRouteFuji);
        vm.stopPrank();

        assertEq(registry.bridgeContract(key, ARC_TESTNET), warpRouteArc);
        assertEq(registry.bridgeContract(key, FUJI), warpRouteFuji);
    }

    function test_disableAsset() public {
        vm.startPrank(admin);
        bytes32 key = registry.registerAsset("MXNB", 6, AssetRegistry.BridgeStrategy.Hyperlane, ARC_TESTNET);
        assertTrue(registry.getAsset(key).enabled);

        registry.setEnabled(key, false);
        assertFalse(registry.getAsset(key).enabled);

        registry.setEnabled(key, true);
        assertTrue(registry.getAsset(key).enabled);
        vm.stopPrank();
    }

    function test_onlyAdminCanRegister() public {
        bytes32 role = registry.ASSET_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);
    }

    function test_onlyAdminCanSetChainAddress() public {
        vm.prank(admin);
        bytes32 key = registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);

        bytes32 role = registry.ASSET_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        registry.setChainAddress(key, ARC_TESTNET, jpycOnArc);
    }

    function test_onlyAdminCanSetBridgeContract() public {
        vm.prank(admin);
        bytes32 key = registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);

        bytes32 role = registry.ASSET_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        registry.setBridgeContract(key, ARC_TESTNET, warpRouteArc);
    }

    function test_onlyAdminCanSetEnabled() public {
        vm.prank(admin);
        bytes32 key = registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);

        bytes32 role = registry.ASSET_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        vm.prank(outsider);
        registry.setEnabled(key, false);
    }

    function test_revertsOnUnknownAsset() public {
        bytes32 unknown = keccak256("DOES_NOT_EXIST");

        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetNotFound.selector, unknown));
        registry.getAsset(unknown);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetNotFound.selector, unknown));
        registry.setChainAddress(unknown, ARC_TESTNET, jpycOnArc);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetNotFound.selector, unknown));
        registry.setBridgeContract(unknown, ARC_TESTNET, warpRouteArc);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetNotFound.selector, unknown));
        registry.setEnabled(unknown, false);
    }

    function test_listAssets() public {
        vm.startPrank(admin);
        bytes32 usdcKey = registry.registerAsset("USDC", 6, AssetRegistry.BridgeStrategy.CCTP, 0);
        bytes32 eurcKey = registry.registerAsset("EURC", 6, AssetRegistry.BridgeStrategy.CCTP, 0);
        bytes32 jpycKey = registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);
        bytes32 mxnbKey =
            registry.registerAsset("MXNB", 6, AssetRegistry.BridgeStrategy.Hyperlane, ARC_TESTNET);
        vm.stopPrank();

        bytes32[] memory list = registry.listAssets();
        assertEq(list.length, 4);
        assertEq(list[0], usdcKey);
        assertEq(list[1], eurcKey);
        assertEq(list[2], jpycKey);
        assertEq(list[3], mxnbKey);
        assertEq(registry.assetCount(), 4);
    }

    function test_reRegisterDoesNotDuplicateInList() public {
        vm.startPrank(admin);
        registry.registerAsset("JPYC", 18, AssetRegistry.BridgeStrategy.Native, 137);
        assertEq(registry.assetCount(), 1);

        // Overwrite with different decimals — should NOT push a duplicate key.
        bytes32 key = registry.registerAsset("JPYC", 6, AssetRegistry.BridgeStrategy.Hyperlane, 43114);
        vm.stopPrank();

        assertEq(registry.assetCount(), 1);
        AssetRegistry.AssetConfig memory cfg = registry.getAsset(key);
        assertEq(cfg.decimals, 6);
        assertEq(cfg.liquidityHomeChainId, 43114);
        assertEq(uint256(cfg.strategy), uint256(AssetRegistry.BridgeStrategy.Hyperlane));
    }

    function test_registerRejectsEmptySymbol() public {
        vm.prank(admin);
        vm.expectRevert(AssetRegistry.InvalidConfig.selector);
        registry.registerAsset("", 18, AssetRegistry.BridgeStrategy.Native, 137);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(AssetRegistry.InvalidConfig.selector);
        new AssetRegistry(address(0));
    }

    function test_tokenAddressOnChainReturnsZeroWhenUnset() public view {
        // No revert when reading an unset address — useful for "is this asset on this chain?" checks.
        assertEq(registry.tokenAddressOnChain("JPYC", ARC_TESTNET), address(0));
    }
}
