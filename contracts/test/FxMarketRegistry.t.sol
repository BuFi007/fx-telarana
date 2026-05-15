// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice Adversarial unit tests for the registry's caller-level auth gate
///         (Codex Drop-666 review fix). The Morpho-side flows are exercised
///         in MainnetFork.t.sol; here we only assert the revert behavior of
///         the new `NotAuthorizedForOnBehalf` guard.
contract FxMarketRegistryAuthTest is Test {
    FxMarketRegistry internal registry;

    address internal owner = address(0x0FF1CE);
    address internal alice = address(0xA11CE); // victim
    address internal mallory = address(0xBADBABE); // attacker
    address internal morpho = address(0xBBBB);

    function setUp() public {
        // Morpho is not actually called in these tests — the auth gate
        // reverts before any external call. So an EOA-shaped address is fine.
        registry = new FxMarketRegistry(morpho, owner);
    }

    function test_withdraw_revertsIfOnBehalfNotCaller() public {
        vm.prank(mallory);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFxMarketRegistry.NotAuthorizedForOnBehalf.selector,
                alice,
                mallory
            )
        );
        registry.withdraw(address(0xAAAA), address(0xBBBB), 1, alice, mallory);
    }

    function test_withdrawCollateral_revertsIfOnBehalfNotCaller() public {
        vm.prank(mallory);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFxMarketRegistry.NotAuthorizedForOnBehalf.selector,
                alice,
                mallory
            )
        );
        registry.withdrawCollateral(address(0xAAAA), address(0xBBBB), 1, alice, mallory);
    }

    function test_borrow_revertsIfOnBehalfNotCaller() public {
        vm.prank(mallory);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFxMarketRegistry.NotAuthorizedForOnBehalf.selector,
                alice,
                mallory
            )
        );
        registry.borrow(address(0xAAAA), address(0xBBBB), 1, alice, mallory);
    }

    function testFuzz_anyAttackerCannotRouteToVictim(address attacker, address victim, address receiver_) public {
        vm.assume(attacker != victim);
        vm.assume(attacker != address(0));

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFxMarketRegistry.NotAuthorizedForOnBehalf.selector,
                victim,
                attacker
            )
        );
        registry.withdraw(address(0xAAAA), address(0xBBBB), 1, victim, receiver_);
    }
}
