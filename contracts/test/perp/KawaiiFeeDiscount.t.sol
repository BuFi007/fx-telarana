// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {KawaiiFeeDiscount} from "../../src/perp/KawaiiFeeDiscount.sol";
import {IFeeDiscount} from "../../src/perp/interfaces/IFeeDiscount.sol";

/// @notice Minimal ERC-721-shaped mock: only balanceOf(address).
contract MockERC721 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// @notice Minimal ERC-1155-shaped mock: only balanceOf(address,uint256).
contract MockERC1155 {
    mapping(address => mapping(uint256 => uint256)) public bal;

    function mint(address to, uint256 id, uint256 amount) external {
        bal[to][id] += amount;
    }

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return bal[account][id];
    }
}

/// @notice NFT whose balanceOf always reverts — proves fail-safe non-holder.
contract RevertingNft {
    function balanceOf(address) external pure returns (uint256) {
        revert("boom");
    }
}

contract KawaiiFeeDiscountTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0B);

    MockERC721 internal erc721;
    MockERC1155 internal erc1155;
    KawaiiFeeDiscount internal disc;

    uint256 internal constant TOKEN_ID = 7;

    function setUp() public {
        erc721 = new MockERC721();
        erc1155 = new MockERC1155();
        // Default to the ERC-721 mock; specific tests re-point as needed.
        disc = new KawaiiFeeDiscount(address(erc721), false, 0, OWNER);
    }

    // --- holder base (VIP0) ---

    function test_erc721HolderGetsVip0() public {
        erc721.mint(ALICE, 1);
        assertEq(disc.discountBps(ALICE), 1000, "VIP0 10% off");
        assertTrue(disc.holdsNft(ALICE));
    }

    function test_nonHolderGetsNoDiscount() public view {
        assertEq(disc.discountBps(BOB), 0, "non-holder full fee");
        assertFalse(disc.holdsNft(BOB));
    }

    function test_erc1155HolderGetsVip0() public {
        vm.prank(OWNER);
        disc.setNft(address(erc1155), true, TOKEN_ID);
        erc1155.mint(ALICE, TOKEN_ID, 1);
        assertEq(disc.discountBps(ALICE), 1000, "1155 holder VIP0");
        // Holding a different id does not count.
        assertEq(disc.discountBps(BOB), 0, "wrong id non-holder");
    }

    function test_revertingNftFailsSafeToNonHolder() public {
        RevertingNft bad = new RevertingNft();
        vm.prank(OWNER);
        disc.setNft(address(bad), false, 0);
        assertFalse(disc.holdsNft(ALICE), "reverting NFT -> not holder");
        assertEq(disc.discountBps(ALICE), 0, "no discount on reverting NFT");
    }

    function test_zeroNftAddressFailsSafe() public {
        vm.prank(OWNER);
        disc.setNft(address(0), false, 0);
        assertEq(disc.discountBps(ALICE), 0);
    }

    // --- power-tier overrides (VIP1..5) ---

    function test_overrideVip5FiftyPercent() public {
        vm.prank(OWNER);
        disc.setDiscount(ALICE, 5000);
        assertEq(disc.discountBps(ALICE), 5000, "VIP5 50% off without NFT");
    }

    function test_effectiveIsMaxOfBaseAndOverride() public {
        erc721.mint(ALICE, 1); // base 1000
        vm.prank(OWNER);
        disc.setDiscount(ALICE, 3000); // VIP3
        assertEq(disc.discountBps(ALICE), 3000, "max(base, override)");

        // Override lower than base -> base wins.
        vm.prank(OWNER);
        disc.setDiscount(ALICE, 500);
        assertEq(disc.discountBps(ALICE), 1000, "base wins when override lower");
    }

    function test_setDiscountRejectsAboveCap() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(KawaiiFeeDiscount.InvalidBps.selector, uint16(6000)));
        disc.setDiscount(ALICE, 6000);
    }

    function test_batchSetDiscounts() public {
        address[] memory traders = new address[](2);
        traders[0] = ALICE;
        traders[1] = BOB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 2000;
        bps[1] = 4000;
        vm.prank(OWNER);
        disc.setDiscounts(traders, bps);
        assertEq(disc.discountBps(ALICE), 2000);
        assertEq(disc.discountBps(BOB), 4000);
    }

    function test_batchRejectsLengthMismatch() public {
        address[] memory traders = new address[](2);
        uint16[] memory bps = new uint16[](1);
        vm.prank(OWNER);
        vm.expectRevert(KawaiiFeeDiscount.LengthMismatch.selector);
        disc.setDiscounts(traders, bps);
    }

    function test_batchRejectsAboveCap() public {
        address[] memory traders = new address[](1);
        traders[0] = ALICE;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 5001;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(KawaiiFeeDiscount.InvalidBps.selector, uint16(5001)));
        disc.setDiscounts(traders, bps);
    }

    function test_setHolderBaseBps() public {
        vm.prank(OWNER);
        disc.setHolderBaseBps(1500); // VIP1 base
        erc721.mint(ALICE, 1);
        assertEq(disc.discountBps(ALICE), 1500);
    }

    function test_setHolderBaseRejectsAboveCap() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(KawaiiFeeDiscount.InvalidBps.selector, uint16(5001)));
        disc.setHolderBaseBps(5001);
    }

    // --- access control ---

    function test_onlyOwnerSetters() public {
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        disc.setDiscount(ALICE, 1000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        disc.setNft(address(erc1155), true, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        disc.setHolderBaseBps(2000);
        vm.stopPrank();
    }

    function test_maxConstant() public view {
        assertEq(disc.MAX_DISCOUNT_BPS(), 5000);
    }

    // --- VIP ladder mapping sanity (off-chain resolved, on-chain stored) ---

    function test_vipLadderValues() public {
        uint16[6] memory ladder = [uint16(1000), 1500, 2000, 3000, 4000, 5000];
        for (uint256 i = 0; i < ladder.length; i++) {
            vm.prank(OWNER);
            disc.setDiscount(ALICE, ladder[i]);
            assertEq(disc.discountBps(ALICE), ladder[i], "VIP tier value");
        }
    }
}
