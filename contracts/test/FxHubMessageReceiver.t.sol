// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {IFxHubMessageReceiver} from "../src/interfaces/IFxHubMessageReceiver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMessageTransmitter} from "./mocks/MockMessageTransmitter.sol";
import {CctpMessageBuilder} from "./utils/CctpMessageBuilder.sol";

/// @notice Stand-in for FxMarketRegistry. Toggles revert behavior, records calls,
///         and (since Codex-flagged Drop 5/666 fix) optionally pulls a configurable
///         amount of USDC from msg.sender via transferFrom — modeling a real
///         registry that consumes the bridged funds. By default it pulls the full
///         allowance, so executeDeposit's consumption invariant is satisfied and
///         the happy-path assertions still hold.
contract MockTarget {
    bool public revertOnCall;
    bytes public lastCalldata;
    uint256 public callCount;
    MockERC20 public asset;
    /// @notice Amount this mock pulls from msg.sender's allowance on each call.
    ///         0 = "don't pull" (the partial-consumption regression case).
    uint256 public pullAmount;
    /// @notice If true, pull whatever allowance is granted (mirrors a real
    ///         registry that consumes the entire `minted` approval).
    bool public pullFull = true;

    function setRevert(bool v) external { revertOnCall = v; }
    function setAsset(MockERC20 a) external { asset = a; }
    function setPullAmount(uint256 amount, bool full) external {
        pullAmount = amount;
        pullFull = full;
    }

    fallback() external payable {
        lastCalldata = msg.data;
        callCount++;
        if (revertOnCall) revert("mock target reverts");

        if (address(asset) != address(0)) {
            uint256 amt = pullFull
                ? asset.allowance(msg.sender, address(this))
                : pullAmount;
            if (amt > 0) {
                asset.transferFrom(msg.sender, address(this), amt);
            }
        }
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
        target.setAsset(usdc);
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
        // Mock target consumes the full bridged amount (default behavior since
        // the Codex fix). Receiver's balance should drop back to its baseline.
        assertEq(usdc.balanceOf(address(receiver)), 0);
        assertEq(usdc.balanceOf(address(target)), 1_000_000);
    }

    function test_executeDeposit_accountsForCctpFee() public {
        // burnAmount = 1_010_000, feeExecuted = 10_000 → minted = 1_000_000
        bytes memory hubCalldata = hex"deadbeef";
        bytes32 nonce = keccak256("n_fee");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_010_000, 10_000, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);
        // Target pulled the full 1_000_000 minted (default mock behavior).
        assertEq(usdc.balanceOf(address(target)), 1_000_000);
        assertEq(usdc.balanceOf(address(receiver)), 0);
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
        // Healthy deposit — mock target pulls the full bridged amount so
        // the deposit lands as Executed (not Stranded). Sweep should
        // revert with NotStranded.
        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_healthy");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);
        // sanity: this deposit is Executed, not Stranded.
        assertEq(uint8(receiver.depositState(nonce)), uint8(IFxHubMessageReceiver.DepositState.Executed));

        skip(receiver.STRANDED_DEPOSIT_GRACE() + 1);
        vm.expectRevert();
        receiver.sweepStrandedDeposit(nonce);
    }

    /*//////////////////////////////////////////////////////////////
        ADVERSARIAL — Codex Drop-666 review fix:
        a hubCalldata that "succeeds" but doesn't consume the bridged
        USDC must NOT mark the deposit Executed. Prior behavior stranded
        the leftover funds permanently (no path to recovery).
    //////////////////////////////////////////////////////////////*/

    function test_executeDeposit_partialConsumption_isStrandedNotExecuted() public {
        // Mock pulls only 1 USDC out of 1,000,000 minted.
        target.setPullAmount(1, false);

        bytes memory hubCalldata = hex"feedbabe";
        bytes32 nonce = keccak256("n_partial");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        // 999_999 USDC parked on receiver — must be Stranded, not Executed.
        IFxHubMessageReceiver.StrandedDeposit memory d = receiver.strandedDeposit(nonce);
        assertEq(uint8(d.state), uint8(IFxHubMessageReceiver.DepositState.Stranded));
        assertEq(uint256(d.amount), 999_999);
        assertEq(usdc.balanceOf(address(receiver)), 999_999);
        // Sweep recovers it after grace.
        skip(receiver.STRANDED_DEPOSIT_GRACE() + 1);
        receiver.sweepStrandedDeposit(nonce);
        assertEq(usdc.balanceOf(alice), 999_999);
    }

    function test_executeDeposit_zeroConsumption_isStrandedNotExecuted() public {
        // Mock succeeds but pulls nothing — exactly the Codex attack vector.
        target.setPullAmount(0, false);

        bytes memory hubCalldata = hex"00";
        bytes32 nonce = keccak256("n_zero");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        IFxHubMessageReceiver.StrandedDeposit memory d = receiver.strandedDeposit(nonce);
        assertEq(uint8(d.state), uint8(IFxHubMessageReceiver.DepositState.Stranded));
        assertEq(uint256(d.amount), 1_000_000);
        // Approval to target must be zero after the call.
        assertEq(usdc.allowance(address(receiver), address(target)), 0);
    }

    function test_executeDeposit_tightApproval_caps_at_minted() public {
        // Pre-fund the receiver with an extra 500 USDC (simulates a
        // prior unrelated stranded deposit). A malicious hubCalldata
        // shouldn't be able to pull more than this deposit's minted
        // amount.
        usdc.mint(address(receiver), 500);
        target.setPullAmount(type(uint256).max, true); // pull everything allowed

        bytes memory hubCalldata = hex"cafebabe";
        bytes32 nonce = keccak256("n_tight");
        bytes memory hookData = abi.encode(alice, hubCalldata);
        bytes memory msgBytes = CctpMessageBuilder.build(nonce, address(receiver), 1_000_000, 0, hookData);

        receiver.executeDeposit(msgBytes, "", alice, hubCalldata);

        // Target pulled exactly 1_000_000 (this deposit's minted), not 1_000_500.
        assertEq(usdc.balanceOf(address(target)), 1_000_000);
        // Pre-existing 500 still parked on the receiver.
        assertEq(usdc.balanceOf(address(receiver)), 500);
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
