// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxPrivacyPool} from "../src/hub/FxPrivacyPool.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

import {Constants} from "privacy-pools/contracts/lib/Constants.sol";
import {IPrivacyPool} from "privacy-pools/interfaces/IPrivacyPool.sol";
import {IState} from "privacy-pools/interfaces/IState.sol";
import {IVerifier} from "privacy-pools/interfaces/IVerifier.sol";

/// @notice Stub Groth16 verifier that always passes — slice-1 tests assert
///         contract plumbing (state transitions, access control, asset flow)
///         not the underlying ZK proof. Real proof verification is exercised
///         in slice-4 SDK tests once the snarkjs witness pipeline lands.
contract MockVerifier is IVerifier {
    function verifyProof(
        uint256[2] memory,
        uint256[2][2] memory,
        uint256[2] memory,
        uint256[8] memory
    ) external pure returns (bool) {
        return true;
    }

    function verifyProof(
        uint256[2] memory,
        uint256[2][2] memory,
        uint256[2] memory,
        uint256[4] memory
    ) external pure returns (bool) {
        return true;
    }
}

contract FxPrivacyPoolTest is Test {
    address constant ENTRYPOINT = address(0x1111);
    address constant OWNER      = address(0xABCD);
    address constant USER       = address(0xBEEF);

    MockStablecoin internal usdc;
    MockVerifier   internal withdrawalVerifier;
    MockVerifier   internal ragequitVerifier;
    FxPrivacyPool  internal pool;

    function setUp() public {
        usdc                = new MockStablecoin("USD Coin", "USDC", 6, address(this));
        withdrawalVerifier  = new MockVerifier();
        ragequitVerifier    = new MockVerifier();

        pool = new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            OWNER
        );

        usdc.mint(ENTRYPOINT, 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnNativeAsset() public {
        vm.expectRevert(); // NativeAssetNotSupported() on IPrivacyPoolComplex
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            Constants.NATIVE_ASSET,
            OWNER
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            address(0)
        );
    }

    function test_constructor_setsImmutables() public view {
        assertEq(pool.ASSET(),                       address(usdc));
        assertEq(address(pool.ENTRYPOINT()),         ENTRYPOINT);
        assertEq(address(pool.WITHDRAWAL_VERIFIER()), address(withdrawalVerifier));
        assertEq(address(pool.RAGEQUIT_VERIFIER()),  address(ragequitVerifier));
        assertEq(pool.owner(),                       OWNER);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function test_transferOwner_succeedsForOwner() public {
        address newOwner = address(0xCAFE);
        vm.prank(OWNER);
        pool.transferOwner(newOwner);
        assertEq(pool.owner(), newOwner);
    }

    function test_transferOwner_revertsForNonOwner() public {
        vm.expectRevert(FxPrivacyPool.NotOwner.selector);
        vm.prank(USER);
        pool.transferOwner(USER);
    }

    function test_transferOwner_revertsForZeroAddress() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        vm.prank(OWNER);
        pool.transferOwner(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT (via Entrypoint)
    //////////////////////////////////////////////////////////////*/

    function test_deposit_revertsForNonEntrypoint() public {
        vm.expectRevert(IState.OnlyEntrypoint.selector);
        vm.prank(USER);
        pool.deposit(USER, 100e6, _fakePrecommitment(1));
    }

    function test_deposit_succeedsFromEntrypoint() public {
        uint256 amount = 100e6;
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), amount);
        uint256 commitment = pool.deposit(USER, amount, _fakePrecommitment(2));
        vm.stopPrank();

        assertGt(commitment, 0);
        assertEq(usdc.balanceOf(address(pool)), amount);
    }

    function test_deposit_recordsDepositor() public {
        uint256 amount = 50e6;
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), amount);
        pool.deposit(USER, amount, _fakePrecommitment(3));
        vm.stopPrank();

        assertEq(pool.nonce(), 1);
    }

    function test_deposit_revertsWhenDead() public {
        vm.prank(ENTRYPOINT);
        pool.windDown();

        vm.expectRevert(IState.PoolIsDead.selector);
        vm.prank(ENTRYPOINT);
        pool.deposit(USER, 100e6, _fakePrecommitment(4));
    }

    function test_deposit_revertsOnValueOverflow() public {
        vm.expectRevert(IPrivacyPool.InvalidDepositValue.selector);
        vm.prank(ENTRYPOINT);
        pool.deposit(USER, type(uint128).max, _fakePrecommitment(5));
    }

    /*//////////////////////////////////////////////////////////////
                          WIND DOWN
    //////////////////////////////////////////////////////////////*/

    function test_windDown_revertsForNonEntrypoint() public {
        vm.expectRevert(IState.OnlyEntrypoint.selector);
        vm.prank(OWNER);
        pool.windDown();
    }

    function test_windDown_setsDead() public {
        vm.prank(ENTRYPOINT);
        pool.windDown();
        assertTrue(pool.dead());
    }

    function test_windDown_revertsIfAlreadyDead() public {
        vm.prank(ENTRYPOINT);
        pool.windDown();

        vm.expectRevert(IState.PoolIsDead.selector);
        vm.prank(ENTRYPOINT);
        pool.windDown();
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE ASSET REJECTION
    //////////////////////////////////////////////////////////////*/

    function test_deposit_rejectsNativeValue() public {
        vm.deal(ENTRYPOINT, 1 ether);
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(); // NativeAssetNotAccepted (IPrivacyPoolComplex error)
        pool.deposit{value: 1}(USER, 100e6, _fakePrecommitment(6));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fakePrecommitment(uint256 salt) internal pure returns (uint256) {
        // Any non-zero field-fitting value works for the deposit codepath.
        return uint256(keccak256(abi.encode("precommitment", salt))) %
               Constants.SNARK_SCALAR_FIELD;
    }
}
