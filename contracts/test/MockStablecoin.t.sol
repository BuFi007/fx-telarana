// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

contract MockStablecoinTest is Test {
    address internal owner = address(0x0FF1CE);
    address internal alice = address(0xA11CE);

    function test_ownerCanMintAndDecimalsAreFixed() public {
        MockStablecoin token = new MockStablecoin("Mock MXNB", "mMXNB", 6, owner);

        vm.prank(owner);
        token.mint(alice, 123e6);

        assertEq(token.decimals(), 6);
        assertEq(token.balanceOf(alice), 123e6);
    }

    function test_faucetClosedByDefault() public {
        MockStablecoin token = new MockStablecoin("Mock JPYC", "mJPYC", 18, owner);

        vm.expectRevert(MockStablecoin.FaucetClosed.selector);
        token.faucet();
    }

    function test_faucetMintsDecimalAdjustedAmountWhenOpen() public {
        MockStablecoin token = new MockStablecoin("Mock KRW1", "mKRW1", 0, owner);

        vm.prank(owner);
        token.setFaucetOpen(true);

        vm.prank(alice);
        token.faucet();

        assertEq(token.balanceOf(alice), 1_000);
    }

    function test_onlyOwnerCanOpenFaucetOrMint() public {
        MockStablecoin token = new MockStablecoin("Mock ZCHF", "mZCHF", 18, owner);

        vm.prank(alice);
        vm.expectRevert();
        token.setFaucetOpen(true);

        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1);
    }
}
