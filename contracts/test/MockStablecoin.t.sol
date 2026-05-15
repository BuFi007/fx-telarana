// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Coverage for the parameterized MockStablecoin used to stand in for
///         the regulated stablecoin basket (AUDF/BRLA/JPYC/MXNB/PHPC/ZCHF/KRW1)
///         on Arc testnet until issuer-side mainnet deployments arrive on Arc.
contract MockStablecoinTest is Test {
    MockStablecoin internal token6;   // 6-dec asset (AUDF / MXNB / PHPC / USDC-style)
    MockStablecoin internal token18;  // 18-dec asset (BRLA / JPYC / ZCHF)

    address internal owner = address(0xA11CE);
    address internal alice = address(0xBEEF);
    address internal bob   = address(0xCAFE);

    function setUp() public {
        token6  = new MockStablecoin("Mock 6-Dec",  "MOCK6",  6,  owner);
        token18 = new MockStablecoin("Mock 18-Dec", "MOCK18", 18, owner);
    }

    /*//////////////////////////////////////////////////////////////
                              DECIMALS
    //////////////////////////////////////////////////////////////*/

    function test_DecimalsRespectsConstructor_6() public view {
        assertEq(token6.decimals(), 6);
    }

    function test_DecimalsRespectsConstructor_18() public view {
        assertEq(token18.decimals(), 18);
    }

    function testFuzz_DecimalsArbitrary(uint8 d) public {
        vm.assume(d <= 36); // sane upper bound matching real-world tokens
        MockStablecoin t = new MockStablecoin("X", "X", d, owner);
        assertEq(t.decimals(), d);
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER MINT
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanMint() public {
        vm.prank(owner);
        token6.mint(alice, 1_000_000); // 1.0 token at 6 dec
        assertEq(token6.balanceOf(alice), 1_000_000);
        assertEq(token6.totalSupply(), 1_000_000);
    }

    function test_NonOwnerCannotMint() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token6.mint(alice, 1);
    }

    /*//////////////////////////////////////////////////////////////
                              FAUCET
    //////////////////////////////////////////////////////////////*/

    function test_FaucetClosedByDefault() public {
        vm.expectRevert(MockStablecoin.FaucetClosed.selector);
        vm.prank(alice);
        token6.faucet();
    }

    function test_OwnerOpensFaucetThenAnyoneCanClaim() public {
        vm.prank(owner);
        token6.setFaucetOpen(true);
        assertTrue(token6.faucetOpen());

        vm.prank(alice);
        token6.faucet();
        // 1000 whole tokens * 10^6 decimals
        assertEq(token6.balanceOf(alice), 1_000 * 10**6);

        vm.prank(bob);
        token6.faucet();
        assertEq(token6.balanceOf(bob), 1_000 * 10**6);
    }

    function test_FaucetPayoutScalesWithDecimals() public {
        vm.prank(owner);
        token18.setFaucetOpen(true);

        vm.prank(alice);
        token18.faucet();
        // 1000 whole tokens * 10^18 decimals — critical for JPYC/BRLA/ZCHF
        assertEq(token18.balanceOf(alice), 1_000 * 10**18);
    }

    function test_OwnerCanCloseFaucet() public {
        vm.prank(owner);
        token6.setFaucetOpen(true);

        vm.prank(owner);
        token6.setFaucetOpen(false);

        vm.expectRevert(MockStablecoin.FaucetClosed.selector);
        vm.prank(alice);
        token6.faucet();
    }

    function test_NonOwnerCannotToggleFaucet() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token6.setFaucetOpen(true);
    }

    /*//////////////////////////////////////////////////////////////
                              BURN (from ERC20Burnable)
    //////////////////////////////////////////////////////////////*/

    function test_HolderCanBurn() public {
        vm.prank(owner);
        token6.mint(alice, 100);

        vm.prank(alice);
        token6.burn(40);

        assertEq(token6.balanceOf(alice), 60);
        assertEq(token6.totalSupply(), 60);
    }

    /*//////////////////////////////////////////////////////////////
                              PERMIT (EIP-2612)
    //////////////////////////////////////////////////////////////*/

    function test_PermitSetsAllowance() public {
        // Build a signed permit from a deterministic PK; verify allowance lands.
        uint256 pk = 0xA11CE_1234;
        address holder = vm.addr(pk);

        vm.prank(owner);
        token6.mint(holder, 1_000);

        uint256 value = 500;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token6.nonces(holder);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                holder,
                bob,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token6.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        token6.permit(holder, bob, value, deadline, v, r, s);

        assertEq(token6.allowance(holder, bob), value);
        assertEq(token6.nonces(holder), nonce + 1);
    }

    /*//////////////////////////////////////////////////////////////
                              METADATA
    //////////////////////////////////////////////////////////////*/

    function test_NameAndSymbolPropagate() public view {
        assertEq(token6.name(), "Mock 6-Dec");
        assertEq(token6.symbol(), "MOCK6");
        assertEq(token18.name(), "Mock 18-Dec");
        assertEq(token18.symbol(), "MOCK18");
    }

    function test_OwnerIsConstructorParam() public view {
        assertEq(token6.owner(), owner);
        assertEq(token18.owner(), owner);
    }
}
