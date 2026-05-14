// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {IFxHubMessageReceiver} from "../src/interfaces/IFxHubMessageReceiver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMessageTransmitter} from "./mocks/MockMessageTransmitter.sol";
import {CctpMessageBuilder} from "./utils/CctpMessageBuilder.sol";

/// @notice Stand-in for FxMarketRegistry. Lets us toggle revert behavior + record calls.
contract MockTarget {
    bool public revertOnCall;
    bytes public lastCalldata;
    uint256 public callCount;

    function setRevert(bool v) external { revertOnCall = v; }

    fallback() external payable {
        lastCalldata = msg.data;
        callCount++;
        if (revertOnCall) revert("mock target reverts");
    }
}

contract FxHubMessageReceiverTest is Test {
    FxHubMessageReceiver internal receiver;
    MockMessageTransmitter internal mt;
    MockERC20 internal usdc;
    MockTarget internal target;

    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mt = new MockMessageTransmitter(usdc, 26);
        target = new MockTarget();
        receiver = new FxHubMessageReceiver(address(mt), address(usdc), address(target));
    }

    /*//////////////////////////////////////////////////////////////
                                HAPPY
    //////////////////////////////////////////////////////////////*/

    function test_executeDeposit_happyPath() public {
        bytes memory hubCalldata = abi.encodeWithSignature("supply(address,address,uint256,address)", address(usdc), address(0), uint256(1_000_000), alice);
        bytes32 nonce = keccak256("n1");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        assertEq(uint8(receiver.depositState(nonce)), uint8(IFxHubMessageReceiver.DepositState.Executed));
        assertEq(target.callCount(), 1);
        assertEq(target.lastCalldata(), hubCalldata);
        // USDC was approved to target; mock target doesn't pull, so balance stays at receiver
        assertEq(usdc.balanceOf(address(receiver)), 1_000_000);
    }

    function test_executeDeposit_accountsForCctpFee() public {
        // burnAmount = 1_010_000, feeExecuted = 10_000 → minted = 1_000_000
        bytes memory hubCalldata = hex"deadbeef";
        bytes32 nonce = keccak256("n_fee");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_010_000, 10_000, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);
        assertEq(usdc.balanceOf(address(receiver)), 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                                NEGATIVE
    //////////////////////////////////////////////////////////////*/

    function test_executeDeposit_revertsOnMintRecipientMismatch() public {
        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_mismatch");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(0xBEEF), 1_000_000, 0, hookData);

        vm.expectRevert();
        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);
    }

    function test_executeDeposit_revertsOnHookMismatch() public {
        bytes memory realCalldata = hex"deadbeef";
        bytes memory tampered = hex"deadbe00";
        bytes32 nonce = keccak256("n_hook");
        bytes memory hookData = abi.encode(alice, realCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        vm.expectRevert();
        receiver.executeDeposit(msgBytes, "", alice, tampered);
    }

    function test_executeDeposit_revertsOnReplay() public {
        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_dup");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);
        vm.expectRevert();
        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);
    }

    /*//////////////////////////////////////////////////////////////
                                STRANDED + SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_executeDeposit_strandsOnTargetRevert() public {
        target.setRevert(true);

        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_strand");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        IFxHubMessageReceiver.StrandedDeposit memory d = receiver.strandedDeposit(nonce);
        assertEq(uint8(d.state), uint8(IFxHubMessageReceiver.DepositState.Stranded));
        assertEq(d.beneficiary, alice);
        assertEq(uint256(d.amount), 1_000_000);
        assertEq(usdc.balanceOf(address(receiver)), 1_000_000);
        // Approval to registry should be zeroed
        assertEq(usdc.allowance(address(receiver), address(target)), 0);
    }

    function test_sweepStrandedDeposit_afterGrace() public {
        target.setRevert(true);
        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_sw");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        skip(receiver.STRANDED_DEPOSIT_GRACE() + 1);
        receiver.sweepStrandedDeposit(nonce);

        assertEq(usdc.balanceOf(alice), 1_000_000);
        assertEq(usdc.balanceOf(address(receiver)), 0);
        assertEq(uint8(receiver.depositState(nonce)), uint8(IFxHubMessageReceiver.DepositState.Swept));
    }

    function test_sweepStrandedDeposit_revertsBeforeGrace() public {
        target.setRevert(true);
        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_early");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        // 1 second before grace ends
        skip(receiver.STRANDED_DEPOSIT_GRACE() - 1);
        vm.expectRevert();
        receiver.sweepStrandedDeposit(nonce);
    }

    function test_sweepStrandedDeposit_revertsOnNonStranded() public {
        // Healthy deposit
        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_healthy");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        skip(receiver.STRANDED_DEPOSIT_GRACE() + 1);
        vm.expectRevert();
        receiver.sweepStrandedDeposit(nonce);
    }

    function test_sweepStrandedDeposit_revertsOnDoubleSweep() public {
        target.setRevert(true);
        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_double");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);
        skip(receiver.STRANDED_DEPOSIT_GRACE() + 1);
        receiver.sweepStrandedDeposit(nonce);
        vm.expectRevert();
        receiver.sweepStrandedDeposit(nonce);
    }
}
