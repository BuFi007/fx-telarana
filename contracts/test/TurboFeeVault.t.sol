// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TurboFeeVault} from "../src/hub/TurboFeeVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TurboFeeVaultTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal eurc;
    TurboFeeVault internal vault;

    address internal constant ADMIN = address(uint160(uint256(keccak256("vault.ADMIN"))));
    address internal constant TREASURY = address(uint160(uint256(keccak256("vault.TREASURY"))));
    address internal constant DEPOSITOR = address(uint160(uint256(keccak256("vault.DEPOSITOR"))));
    address internal constant LP = address(uint160(uint256(keccak256("vault.LP"))));
    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        vault = new TurboFeeVault(IERC20(address(usdc)), TREASURY);

        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), DEPOSITOR);

        usdc.mint(LP, 1_000e6);
        vm.startPrank(LP);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();
    }

    function test_depositFeeSplitsProtocolYieldAndInsurance() public {
        usdc.mint(DEPOSITOR, 100e6);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(vault), 100e6);
        vault.depositFee(address(usdc), 100e6, MARKET_ID);
        vm.stopPrank();

        assertEq(usdc.balanceOf(TREASURY), 50e6, "protocol share");
        assertEq(vault.pendingYield(LP), 40e6, "LP yield");
        assertEq(vault.insuranceBalance(), 10e6, "insurance share");

        vm.prank(LP);
        vault.claimYield();
        assertEq(usdc.balanceOf(LP), 40e6, "claimed yield");
    }

    function test_revertsForUnsupportedFeeToken() public {
        eurc.mint(DEPOSITOR, 1e6);
        vm.startPrank(DEPOSITOR);
        eurc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(TurboFeeVault.UnsupportedFeeToken.selector, address(eurc)));
        vault.depositFee(address(eurc), 1e6, MARKET_ID);
        vm.stopPrank();
    }

    function _depositFee(uint256 amount) internal {
        usdc.mint(DEPOSITOR, amount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(vault), amount);
        vault.depositFee(address(usdc), amount, MARKET_ID);
        vm.stopPrank();
    }

    /// @dev F-10: insurance payout goes to the governance-set beneficiary, never
    ///      to the caller (closes the INSURANCE_ADMIN self-drain).
    function test_insurancePayout_goesToBeneficiaryNotCaller() public {
        address insuranceAdmin = address(0x1A5A);
        address beneficiary = address(0xB0FE);
        vault.grantRole(vault.INSURANCE_ADMIN_ROLE(), insuranceAdmin);
        vault.setInsuranceBeneficiary(beneficiary);

        _depositFee(100e6); // insuranceBalance = 10e6
        assertEq(vault.insuranceBalance(), 10e6);

        vm.prank(insuranceAdmin);
        vault.insurancePayout(MARKET_ID, 10e6, "claim");

        assertEq(usdc.balanceOf(beneficiary), 10e6, "beneficiary paid");
        assertEq(usdc.balanceOf(insuranceAdmin), 0, "caller got nothing");
        assertEq(vault.insuranceBalance(), 0);
    }

    /// @dev F-23: with no stakers, the 40% LP share is held for future stakers,
    ///      not captured by the insurance fund. The first staker collects it.
    function test_lpShareHeldForFutureStakers_whenNoStakers() public {
        TurboFeeVault fresh = new TurboFeeVault(IERC20(address(usdc)), TREASURY);
        fresh.grantRole(fresh.FEE_DEPOSITOR_ROLE(), DEPOSITOR);

        usdc.mint(DEPOSITOR, 100e6);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(fresh), 100e6);
        fresh.depositFee(address(usdc), 100e6, MARKET_ID);
        vm.stopPrank();

        assertEq(fresh.insuranceBalance(), 10e6, "only the 10% insurance share captured");
        assertEq(fresh.pendingLpRewards(), 40e6, "LP share held pending");

        usdc.mint(LP, 1_000e6);
        vm.startPrank(LP);
        usdc.approve(address(fresh), 1_000e6);
        fresh.deposit(1_000e6); // first staker folds in the pending LP share
        uint256 claimed = fresh.claimYield();
        vm.stopPrank();

        assertEq(claimed, 40e6, "first staker collects the previously-pending LP share");
        assertEq(fresh.pendingLpRewards(), 0);
    }

    /// @dev F-24: the optional cooldown locks staked principal, defeating the
    ///      same-block deposit→fee→withdraw sandwich.
    function test_withdrawCooldown_enforced() public {
        vault.setWithdrawCooldown(1 days);

        usdc.mint(DEPOSITOR, 500e6);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(vault), 500e6);
        uint256 sh = vault.deposit(500e6);

        vm.expectRevert(
            abi.encodeWithSelector(TurboFeeVault.WithdrawLocked.selector, block.timestamp + 1 days)
        );
        vault.withdraw(sh);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(DEPOSITOR);
        vault.withdraw(sh); // unlocked
    }
}
