// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {FxRouter, IFxRouterSwapAdapter} from "../src/hub/FxRouter.sol";
import {IFxRouter} from "../src/interfaces/IFxRouter.sol";
import {FxRouterLib} from "../src/libraries/FxRouterLib.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";

contract FxRouterTest is Test {
    FxRouter           internal router;
    MockPermit2        internal permit2;
    MockSwapAdapter    internal adapter;
    MockERC20          internal usdc;
    MockERC20          internal eurc;

    address internal owner    = address(0xA11CE);
    address internal treasury = address(0xFEE5);
    uint48  internal constant MAX_FEE_BPS = uint48(10 * FxRouterLib.BPS_DENOMINATOR / 10_000); // 10 bps

    // Taker EOA — we sign with this PK in-test.
    uint256 internal takerPk = 0xA11CE_B0B;
    address internal taker;
    address internal recipient = address(0xBEEF);

    function setUp() public {
        taker = vm.addr(takerPk);

        permit2 = new MockPermit2();
        adapter = new MockSwapAdapter();
        usdc    = new MockERC20("USD Coin", "USDC", 6);
        eurc    = new MockERC20("Euro Coin", "EURC", 6);

        router = new FxRouter(
            address(permit2),
            address(adapter),
            treasury,
            MAX_FEE_BPS,
            owner
        );

        // Allow the USDC -> EURC pair
        vm.prank(owner);
        router.setPairAllowed(address(usdc), address(eurc), true);

        // Fund taker + adapter
        usdc.mint(taker, 1_000_000e6);
        eurc.mint(address(adapter), 1_000_000e6);

        // Taker pre-approves the Mock Permit2 (mirrors the canonical pattern:
        // users do a one-time ERC-20 approve of the Permit2 contract).
        vm.prank(taker);
        usdc.approve(address(permit2), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _baseIntent() internal view returns (FxRouterLib.FxIntent memory intent) {
        intent = FxRouterLib.FxIntent({
            taker:        taker,
            recipient:    recipient,
            sellToken:    address(usdc),
            buyToken:     address(eurc),
            sellAmount:   1_000e6,
            minBuyAmount: 990e6,
            deadline:     uint48(block.timestamp + 600),
            feeBps:       uint48(5 * FxRouterLib.BPS_DENOMINATOR / 10_000), // 5 bps
            tenor:        FxRouterLib.TENOR_INSTANT,
            quoteId:      bytes32("quote-1"),
            uuid:         1
        });
    }

    function _encodePermit(address token, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        ISignatureTransfer.PermitTransferFrom memory p = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token:  token,
                amount: amount
            }),
            nonce:    0,
            deadline: block.timestamp + 600
        });
        return abi.encode(p);
    }

    function _signIntent(FxRouterLib.FxIntent memory intent, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = FxRouterLib.hashIntentMemory(intent);
        bytes32 domainSep  = router.domainSeparator();
        bytes32 digest     = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_executeIntent_happyPath() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        uint256 takerUsdcBefore     = usdc.balanceOf(taker);
        uint256 recipientEurcBefore = eurc.balanceOf(recipient);
        uint256 treasuryUsdcBefore  = usdc.balanceOf(treasury);

        uint256 buyAmount = router.executeIntent(intent, intentSig, permit, "");

        uint256 expectedFee = FxRouterLib.computeFee(intent.sellAmount, intent.feeBps);
        uint256 expectedNet = intent.sellAmount - expectedFee;

        assertEq(buyAmount, expectedNet, "buyAmount = net at 1:1 rate");
        assertEq(usdc.balanceOf(taker), takerUsdcBefore - intent.sellAmount, "taker debited");
        assertEq(eurc.balanceOf(recipient), recipientEurcBefore + buyAmount, "recipient credited");
        assertEq(usdc.balanceOf(treasury), treasuryUsdcBefore + expectedFee, "treasury credited");
        assertTrue(router.isIntentUuidUsed(taker, intent.uuid), "uuid marked used");
    }

    function test_executeIntent_zeroFee_skipsTreasury() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.feeBps = 0;
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 buyAmount      = router.executeIntent(intent, intentSig, permit, "");

        assertEq(buyAmount, intent.sellAmount, "no fee -> full notional swapped");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "treasury untouched");
    }

    /*//////////////////////////////////////////////////////////////
                              REVERT PATHS
    //////////////////////////////////////////////////////////////*/

    function test_revert_intentExpired() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.deadline = uint48(block.timestamp - 1);
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(IFxRouter.IntentExpired.selector);
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_intentDeadlineTooFar() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.deadline = uint48(block.timestamp + FxRouterLib.MAX_DEADLINE_FUTURE + 10);
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFxRouter.IntentDeadlineTooFar.selector,
                uint256(intent.deadline),
                block.timestamp + FxRouterLib.MAX_DEADLINE_FUTURE
            )
        );
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_takerZero() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.taker = address(0);
        // Cannot sign with a meaningful key for address(0), use any sig — TakerZero hits first.
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(IFxRouter.TakerZero.selector);
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_recipientZero() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.recipient = address(0);
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(IFxRouter.RecipientZero.selector);
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_unsupportedTenor() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.tenor = 1; // hourly — reserved
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(abi.encodeWithSelector(IFxRouter.UnsupportedTenor.selector, uint8(1)));
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_unsupportedPair() public {
        // disable the pair
        vm.prank(owner);
        router.setPairAllowed(address(usdc), address(eurc), false);

        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFxRouter.UnsupportedPair.selector, address(usdc), address(eurc)
            )
        );
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_feeBpsTooHigh() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.feeBps = MAX_FEE_BPS + 1;
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFxRouter.FeeBpsTooHigh.selector, intent.feeBps, MAX_FEE_BPS
            )
        );
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_routerPaused() public {
        vm.prank(owner);
        router.setPaused(true);

        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(IFxRouter.RouterPaused.selector);
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_sellTokenMismatch() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        // permit token != intent.sellToken
        bytes memory permit = _encodePermit(address(eurc), intent.sellAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFxRouter.SellTokenMismatch.selector, address(usdc), address(eurc)
            )
        );
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_sellAmountMismatch() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFxRouter.SellAmountMismatch.selector,
                intent.sellAmount,
                intent.sellAmount + 1
            )
        );
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_invalidSignature() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        // Sign with the wrong key
        uint256 wrongPk = 0xBADBAD;
        bytes memory intentSig = _signIntent(intent, wrongPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        vm.expectRevert(IFxRouter.InvalidSignature.selector);
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_uuidAlreadyUsed() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        router.executeIntent(intent, intentSig, permit, "");

        // Re-submit with the same uuid (same signed envelope replay)
        vm.expectRevert(IFxRouter.UuidAlreadyUsed.selector);
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_insufficientOutput() public {
        // Force adapter to return below minBuyAmount
        FxRouterLib.FxIntent memory intent = _baseIntent();
        intent.minBuyAmount = 950e6;
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        adapter.setForcedBuyAmount(900e6); // below minBuyAmount

        vm.expectRevert(
            abi.encodeWithSelector(
                IFxRouter.InsufficientOutput.selector, uint256(900e6), uint256(950e6)
            )
        );
        router.executeIntent(intent, intentSig, permit, "");
    }

    function test_revert_adapterReturnedZero() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);

        adapter.setForcedBuyAmount(0);

        vm.expectRevert(FxRouter.AdapterReturnedZero.selector);
        router.executeIntent(intent, intentSig, permit, "");
    }

    /*//////////////////////////////////////////////////////////////
                              REPLAY PROTECTION
    //////////////////////////////////////////////////////////////*/

    function test_replayProtection_differentUuidWorks() public {
        FxRouterLib.FxIntent memory intent = _baseIntent();
        bytes memory intentSig = _signIntent(intent, takerPk);
        bytes memory permit    = _encodePermit(address(usdc), intent.sellAmount);
        router.executeIntent(intent, intentSig, permit, "");

        // Bump uuid — same taker, fresh envelope.
        intent.uuid = 2;
        intentSig = _signIntent(intent, takerPk);
        permit    = _encodePermit(address(usdc), intent.sellAmount);
        router.executeIntent(intent, intentSig, permit, "");

        assertTrue(router.isIntentUuidUsed(taker, 1), "uuid 1 used");
        assertTrue(router.isIntentUuidUsed(taker, 2), "uuid 2 used");
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setTreasury_onlyOwner() public {
        address newTreasury = address(0xFEED);
        vm.prank(owner);
        router.setTreasury(newTreasury);
        assertEq(router.treasury(), newTreasury);
    }

    function test_setMaxFeeBps_respectsHardCap() public {
        uint48 tooHigh = FxRouterLib.MAX_FEE_BPS_HARD_CAP + 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFxRouter.FeeBpsTooHigh.selector, tooHigh, FxRouterLib.MAX_FEE_BPS_HARD_CAP
            )
        );
        router.setMaxFeeBps(tooHigh);
    }

    function test_setSwapAdapter_works() public {
        MockSwapAdapter newAdapter = new MockSwapAdapter();
        vm.prank(owner);
        router.setSwapAdapter(address(newAdapter));
        assertEq(address(router.swapAdapter()), address(newAdapter));
    }

    function test_setPairAllowed_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(); // OZ Ownable revert
        router.setPairAllowed(address(usdc), address(eurc), false);
    }
}
