// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {KawaiiRebateVault} from "../src/hub/KawaiiRebateVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract KawaiiRebateVaultTest is Test {
    MockERC20 internal usdc;
    KawaiiRebateVault internal vault;

    address internal constant ADMIN = address(uint160(uint256(keccak256("rebate.ADMIN"))));
    address internal constant FUNDER = address(uint160(uint256(keccak256("rebate.FUNDER"))));
    address internal constant KEEPER = address(uint160(uint256(keccak256("rebate.KEEPER"))));
    address internal constant GUARDIAN = address(uint160(uint256(keccak256("rebate.GUARDIAN"))));
    address internal constant ALICE = address(uint160(uint256(keccak256("rebate.ALICE"))));
    address internal constant BOB = address(uint160(uint256(keccak256("rebate.BOB"))));

    uint256 internal constant VEST = 7 days;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(ADMIN);
        vault = new KawaiiRebateVault(IERC20(address(usdc)), VEST, ADMIN);
        vm.startPrank(ADMIN);
        vault.grantRole(vault.REBATE_FUNDER_ROLE(), FUNDER);
        vault.grantRole(vault.REBATE_ALLOCATOR_ROLE(), KEEPER);
        vault.grantRole(vault.PAUSER_ROLE(), GUARDIAN);
        vm.stopPrank();
    }

    function _fund(uint256 amount) internal {
        usdc.mint(FUNDER, amount);
        vm.startPrank(FUNDER);
        usdc.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
    }

    function _solvent() internal view {
        assertGe(
            usdc.balanceOf(address(vault)),
            vault.unallocated() + vault.totalOutstanding(),
            "SOLVENCY VIOLATED"
        );
    }

    function test_fund_raisesUnallocated() public {
        _fund(1_000e6);
        assertEq(vault.unallocated(), 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
        _solvent();
    }

    function test_allocate_revertsWhenUnderfunded() public {
        _fund(100e6);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(KawaiiRebateVault.InsufficientUnallocated.selector, 101e6, 100e6)
        );
        vault.allocate(ALICE, 101e6);
    }

    function test_vesting_isLinear_andClaim() public {
        _fund(1_000e6);
        vm.prank(KEEPER);
        vault.allocate(ALICE, 100e6);

        assertEq(vault.claimable(ALICE), 0, "nothing vested at t0");
        assertEq(vault.unallocated(), 900e6);
        assertEq(vault.totalOutstanding(), 100e6);

        vm.warp(block.timestamp + VEST / 2);
        assertApproxEqAbs(vault.claimable(ALICE), 50e6, 1, "~half vested at midpoint");

        vm.warp(block.timestamp + VEST); // well past full
        assertEq(vault.claimable(ALICE), 100e6, "fully vested");

        vm.prank(ALICE);
        uint256 got = vault.claim();
        assertEq(got, 100e6);
        assertEq(usdc.balanceOf(ALICE), 100e6);
        assertEq(vault.totalOutstanding(), 0);
        _solvent();
    }

    function test_claim_revertsWhenNothing() public {
        vm.prank(ALICE);
        vm.expectRevert(KawaiiRebateVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_topup_foldsRemainder_preservesVested() public {
        _fund(1_000e6);
        vm.prank(KEEPER);
        vault.allocate(ALICE, 100e6);

        vm.warp(block.timestamp + VEST / 2); // 50 vested, 50 still vesting
        assertApproxEqAbs(vault.claimable(ALICE), 50e6, 1);

        vm.prank(KEEPER);
        vault.allocate(ALICE, 100e6); // banks 50, new schedule = 50 + 100 = 150 from now

        assertApproxEqAbs(vault.claimable(ALICE), 50e6, 1, "already-vested preserved across top-up");
        assertApproxEqAbs(vault.totalAllocatedTo(ALICE), 200e6, 1, "lifetime allocated = 200");

        vm.warp(block.timestamp + VEST);
        assertEq(vault.claimable(ALICE), 200e6, "all vests after the folded window");
        _solvent();
    }

    function test_pause_blocksClaimAndAllocate_butNotFund() public {
        _fund(1_000e6);
        vm.prank(KEEPER);
        vault.allocate(ALICE, 100e6);
        vm.warp(block.timestamp + VEST);

        vm.prank(GUARDIAN);
        vault.pause();

        vm.prank(KEEPER);
        vm.expectRevert(); // Pausable: paused
        vault.allocate(BOB, 10e6);

        vm.prank(ALICE);
        vm.expectRevert(); // claim frozen by the circuit breaker
        vault.claim();

        // funding still works while paused (adding backing is safe)
        usdc.mint(FUNDER, 5e6);
        vm.startPrank(FUNDER);
        usdc.approve(address(vault), 5e6);
        vault.fund(5e6);
        vm.stopPrank();

        vm.prank(GUARDIAN);
        vault.unpause();
        vm.prank(ALICE);
        assertEq(vault.claim(), 100e6, "claim works after unpause");
        _solvent();
    }

    function test_accessControl_rolesEnforced() public {
        _fund(100e6);
        vm.prank(ALICE);
        vm.expectRevert(); // not FUNDER
        vault.fund(1e6);

        vm.prank(ALICE);
        vm.expectRevert(); // not ALLOCATOR
        vault.allocate(BOB, 1e6);

        vm.prank(ALICE);
        vm.expectRevert(); // not PAUSER
        vault.pause();
    }

    function test_recoverSurplus_onlySweepsDonation() public {
        _fund(1_000e6);
        vm.prank(KEEPER);
        vault.allocate(ALICE, 400e6); // outstanding 400, unallocated 600 → reserved 1000

        usdc.mint(address(vault), 25e6); // a stray donation

        vm.prank(ADMIN);
        vault.recoverSurplus(ADMIN);
        assertEq(usdc.balanceOf(ADMIN), 25e6, "only the donation swept");
        // reserved funds untouched → still solvent + claimable
        _solvent();
        vm.warp(block.timestamp + VEST);
        vm.prank(ALICE);
        assertEq(vault.claim(), 400e6, "owed rebate still fully claimable");
    }
}

/// @dev Stateful handler for the solvency invariant. Bounds inputs so the fuzzer
///      explores realistic fund/allocate/claim/time sequences.
contract RebateHandler is Test {
    KawaiiRebateVault internal vault;
    MockERC20 internal usdc;
    address internal funder;
    address internal keeper;
    address[3] internal holders;

    constructor(KawaiiRebateVault _vault, MockERC20 _usdc, address _funder, address _keeper) {
        vault = _vault;
        usdc = _usdc;
        funder = _funder;
        keeper = _keeper;
        holders = [address(0xA11CE), address(0xB0B), address(0xCa101)];
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e6);
        usdc.mint(funder, amount);
        vm.startPrank(funder);
        usdc.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
    }

    function allocate(uint256 who, uint256 amount) external {
        uint256 un = vault.unallocated();
        if (un == 0) return;
        amount = bound(amount, 1, un); // never exceed funded (mirrors the guard)
        address h = holders[who % holders.length];
        vm.prank(keeper);
        vault.allocate(h, amount);
    }

    function claim(uint256 who) external {
        address h = holders[who % holders.length];
        if (vault.claimable(h) == 0) return;
        vm.prank(h);
        vault.claim();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }
}

contract KawaiiRebateVaultInvariant is Test {
    MockERC20 internal usdc;
    KawaiiRebateVault internal vault;
    RebateHandler internal handler;

    address internal constant ADMIN = address(uint160(uint256(keccak256("inv.ADMIN"))));
    address internal constant FUNDER = address(uint160(uint256(keccak256("inv.FUNDER"))));
    address internal constant KEEPER = address(uint160(uint256(keccak256("inv.KEEPER"))));

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(ADMIN);
        vault = new KawaiiRebateVault(IERC20(address(usdc)), 7 days, ADMIN);
        vm.startPrank(ADMIN);
        vault.grantRole(vault.REBATE_FUNDER_ROLE(), FUNDER);
        vault.grantRole(vault.REBATE_ALLOCATOR_ROLE(), KEEPER);
        vm.stopPrank();

        handler = new RebateHandler(vault, usdc, FUNDER, KEEPER);
        targetContract(address(handler));
    }

    /// @notice THE core safety property: the vault is always solvent — every
    ///         allocation is fully backed by funded USDC. The keeper can never
    ///         promise a rebate the vault cannot pay.
    function invariant_solvency() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.unallocated() + vault.totalOutstanding());
    }

    /// @notice Accounting identity: balance equals reserved (no donations here).
    function invariant_balanceEqualsReserved() public view {
        assertEq(usdc.balanceOf(address(vault)), vault.unallocated() + vault.totalOutstanding());
    }
}
