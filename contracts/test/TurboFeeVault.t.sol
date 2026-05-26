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
}
