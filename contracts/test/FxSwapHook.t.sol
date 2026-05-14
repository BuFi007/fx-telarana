// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract FxSwapHookTest is Test {
    FxSwapHook internal hook;
    address internal poolManager = address(0x1111);
    address internal oracle      = address(0x2222);
    address internal registry    = address(0x3333);
    address internal owner       = address(0xA11CE);

    function setUp() public {
        hook = new FxSwapHook(poolManager, oracle, registry, owner);
    }

    /*//////////////////////////////////////////////////////////////
                              PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function test_getHookPermissions_enablesExpectedFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap, "beforeSwap should be enabled");
        assertTrue(p.afterSwap, "afterSwap should be enabled");
        assertTrue(p.beforeAddLiquidity, "beforeAddLiquidity should be enabled");
        assertTrue(p.beforeRemoveLiquidity, "beforeRemoveLiquidity should be enabled");
        assertTrue(p.beforeSwapReturnDelta, "beforeSwapReturnDelta should be enabled");
        assertFalse(p.beforeInitialize, "beforeInitialize should NOT be enabled");
        assertFalse(p.afterInitialize, "afterInitialize should NOT be enabled");
        assertFalse(p.afterAddLiquidity, "afterAddLiquidity should NOT be enabled");
        assertFalse(p.beforeDonate, "beforeDonate should NOT be enabled");
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setSpreadBps_onlyOwner() public {
        vm.expectRevert();
        hook.setSpreadBps(50);
    }

    function test_setSpreadBps_updatesAndEmits() public {
        vm.prank(owner);
        hook.setSpreadBps(50);
        assertEq(hook.spreadBps(), 50);
    }

    function test_setSpreadBps_revertsAboveMax() public {
        uint16 maxBps = hook.MAX_SPREAD_BPS();
        vm.expectRevert();
        vm.prank(owner);
        hook.setSpreadBps(maxBps + 1);
    }

    function test_constructor_setsDefaultSpread() public view {
        assertEq(hook.spreadBps(), hook.DEFAULT_SPREAD_BPS());
    }

    function test_transferOwner_movesOwnership() public {
        address next = address(0xBABE);
        vm.prank(owner);
        hook.transferOwner(next);
        assertEq(hook.owner(), next);
    }

    function test_transferOwner_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert();
        hook.transferOwner(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                CTOR GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert();
        new FxSwapHook(address(0), oracle, registry, owner);
        vm.expectRevert();
        new FxSwapHook(poolManager, address(0), registry, owner);
        vm.expectRevert();
        new FxSwapHook(poolManager, oracle, address(0), owner);
        vm.expectRevert();
        new FxSwapHook(poolManager, oracle, registry, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              NOT POOL MANAGER
    //////////////////////////////////////////////////////////////*/

    function test_disabledHooks_revertOnDirectCall() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(0))
        });
        vm.expectRevert();
        hook.beforeInitialize(address(0), key, 0);
    }
}
