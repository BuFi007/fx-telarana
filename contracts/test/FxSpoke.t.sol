// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxSpoke} from "../src/spoke/FxSpoke.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMessageTransmitter} from "./mocks/MockMessageTransmitter.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";

contract FxSpokeTest is Test {
    FxSpoke internal spoke;
    MockTokenMessenger internal messenger;
    MockMessageTransmitter internal mt;
    MockERC20 internal usdc;
    MockERC20 internal eurc;

    address internal hubReceiver = address(0xABC);
    address internal alice = address(0xA11CE);
    address internal beneficiary = address(0xBEEF);

    uint32 internal constant ARC_DOMAIN = 26;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        mt = new MockMessageTransmitter(usdc, 0);
        messenger = new MockTokenMessenger(address(mt));
        spoke = new FxSpoke(address(messenger), address(usdc), hubReceiver, ARC_DOMAIN);

        usdc.mint(alice, 10_000_000);
        eurc.mint(alice, 10_000_000);
        vm.prank(alice);
        usdc.approve(address(spoke), type(uint256).max);
        vm.prank(alice);
        eurc.approve(address(spoke), type(uint256).max);
    }

    function test_enterHub_callsTokenMessengerWithHookData() public {
        bytes memory hubCalldata = hex"deadbeef";
        vm.prank(alice);
        spoke.enterHub(address(usdc), 1_000_000, beneficiary, hubCalldata);

        (
            uint256 amount,
            uint32 destDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destCaller,
            uint256 maxFee,
            uint32 finality,
            bytes memory hookData,
            bool withHook
        ) = messenger.last();

        assertEq(amount, 1_000_000);
        assertEq(destDomain, ARC_DOMAIN);
        assertEq(mintRecipient, bytes32(uint256(uint160(hubReceiver))));
        assertEq(destCaller, bytes32(uint256(uint160(hubReceiver))));
        assertEq(burnToken, address(usdc));
        assertEq(maxFee, spoke.DEFAULT_MAX_FEE());
        assertEq(finality, spoke.FINALITY_FAST());
        assertTrue(withHook);
        assertEq(keccak256(hookData), keccak256(abi.encode(beneficiary, hubCalldata)));
        assertEq(messenger.callCount(), 1);
    }

    function test_enterHub_revertsOnUnsupportedToken() public {
        MockERC20 random = new MockERC20("DAI", "DAI", 18);
        random.mint(alice, 1_000_000);
        vm.startPrank(alice);
        random.approve(address(spoke), type(uint256).max);
        vm.expectRevert();
        spoke.enterHub(address(random), 1_000_000, beneficiary, "");
        vm.stopPrank();
    }

    function test_ownerCanEnableEurcAndEnterHub() public {
        spoke.setCircleTokenAllowed(address(eurc), true);

        bytes memory hubCalldata = hex"cafe";
        vm.prank(alice);
        spoke.enterHub(address(eurc), 2_000_000, beneficiary, hubCalldata);

        (uint256 amount,,, address burnToken,,,, bytes memory hookData, bool withHook) = messenger.last();

        assertEq(amount, 2_000_000);
        assertEq(burnToken, address(eurc));
        assertTrue(withHook);
        assertEq(keccak256(hookData), keccak256(abi.encode(beneficiary, hubCalldata)));
    }

    function test_nonOwnerCannotEnableCircleToken() public {
        vm.prank(alice);
        vm.expectRevert(FxSpoke.NotOwner.selector);
        spoke.setCircleTokenAllowed(address(eurc), true);
    }

    function test_ownerCanTransferCircleAllowlistOwnership() public {
        spoke.transferOwner(beneficiary);
        assertEq(spoke.owner(), beneficiary);

        vm.prank(beneficiary);
        spoke.setCircleTokenAllowed(address(eurc), true);
        assertTrue(spoke.circleTokenAllowed(address(eurc)));
    }

    function test_nonOwnerCannotTransferCircleAllowlistOwnership() public {
        vm.prank(alice);
        vm.expectRevert(FxSpoke.NotOwner.selector);
        spoke.transferOwner(beneficiary);
    }

    function test_enterHub_revertsOnZeroBeneficiary() public {
        vm.prank(alice);
        vm.expectRevert();
        spoke.enterHub(address(usdc), 1_000_000, address(0), "");
    }

    function test_enterHubWithFee_passesCustomFinality() public {
        bytes memory hubCalldata = hex"00";
        uint32 finalThreshold = spoke.FINALITY_FINALIZED();

        vm.prank(alice);
        spoke.enterHubWithFee(address(usdc), 500_000, beneficiary, hubCalldata, 2_000, finalThreshold);

        (,,,,, uint256 maxFee, uint32 finality,, bool withHook) = messenger.last();
        assertEq(maxFee, 2_000);
        assertEq(finality, finalThreshold);
        assertTrue(withHook);
    }

    function test_enterHubWithFee_revertsOnBadFinality() public {
        vm.expectRevert();
        vm.prank(alice);
        spoke.enterHubWithFee(address(usdc), 1, beneficiary, "", 0, 500);
    }
}
