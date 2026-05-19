// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxFixedRateSwapAdapter} from "../src/hub/FxFixedRateSwapAdapter.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

/// @notice Track B unit tests for the fixed-rate adapter.
contract FxFixedRateSwapAdapterTest is Test {
    FxFixedRateSwapAdapter internal adapter;
    MockStablecoin internal usdc;
    MockStablecoin internal eurc;

    address internal constant OWNER  = address(0xA11CE);
    address internal constant CALLER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        usdc = new MockStablecoin("USD Coin", "USDC", 6, address(this));
        eurc = new MockStablecoin("Euro Coin", "EURC", 6, address(this));

        adapter = new FxFixedRateSwapAdapter(OWNER);

        // Pre-fund both legs.
        usdc.mint(address(adapter), 1_000_000 * 10**6); // 1M USDC
        eurc.mint(address(adapter), 1_000_000 * 10**6); // 1M EURC
    }

    /*//////////////////////////////////////////////////////////////
                        construction / admin
    //////////////////////////////////////////////////////////////*/

    function test_owner_setOnConstruction() public view {
        assertEq(adapter.owner(), OWNER, "owner");
    }

    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert(FxFixedRateSwapAdapter.ZeroAddress.selector);
        new FxFixedRateSwapAdapter(address(0));
    }

    function test_transferOwnership() public {
        vm.prank(OWNER);
        adapter.transferOwnership(CALLER);
        assertEq(adapter.owner(), CALLER, "owner rotated");
    }

    function test_transferOwnership_zero_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(FxFixedRateSwapAdapter.ZeroAddress.selector);
        adapter.transferOwnership(address(0));
    }

    function test_transferOwnership_nonOwner_reverts() public {
        vm.expectRevert(FxFixedRateSwapAdapter.NotOwner.selector);
        adapter.transferOwnership(CALLER);
    }

    function test_setRate_persistsAndEmits() public {
        vm.prank(OWNER);
        vm.expectEmit();
        emit FxFixedRateSwapAdapter.RateSet(address(usdc), address(eurc), 0.925e18);
        adapter.setRate(address(usdc), address(eurc), 0.925e18);
        assertEq(adapter.rate(address(usdc), address(eurc)), 0.925e18, "rate stored");
    }

    function test_setRate_nonOwner_reverts() public {
        vm.expectRevert(FxFixedRateSwapAdapter.NotOwner.selector);
        adapter.setRate(address(usdc), address(eurc), 0.925e18);
    }

    function test_setRate_zeroToken_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(FxFixedRateSwapAdapter.ZeroAddress.selector);
        adapter.setRate(address(0), address(eurc), 0.925e18);
    }

    function test_setRate_selfPair_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(FxFixedRateSwapAdapter.SellEqualsBuy.selector);
        adapter.setRate(address(usdc), address(usdc), 0.925e18);
    }

    function test_setEnabled_persistsAndEmits() public {
        vm.prank(OWNER);
        vm.expectEmit();
        emit FxFixedRateSwapAdapter.PairEnabled(address(usdc), address(eurc), true);
        adapter.setEnabled(address(usdc), address(eurc), true);
        assertTrue(adapter.enabled(address(usdc), address(eurc)));
    }

    function test_setEnabled_nonOwner_reverts() public {
        vm.expectRevert(FxFixedRateSwapAdapter.NotOwner.selector);
        adapter.setEnabled(address(usdc), address(eurc), true);
    }

    function test_withdrawLiquidity_movesBalance() public {
        uint256 before = usdc.balanceOf(OWNER);
        vm.prank(OWNER);
        adapter.withdrawLiquidity(IERC20(address(usdc)), OWNER, 100 * 10**6);
        assertEq(usdc.balanceOf(OWNER) - before, 100 * 10**6, "withdrew 100");
    }

    function test_withdrawLiquidity_nonOwner_reverts() public {
        vm.expectRevert(FxFixedRateSwapAdapter.NotOwner.selector);
        adapter.withdrawLiquidity(IERC20(address(usdc)), CALLER, 1);
    }

    /*//////////////////////////////////////////////////////////////
                            swapExactInput
    //////////////////////////////////////////////////////////////*/

    function _enableUsdcEurc(uint256 _rate) internal {
        vm.startPrank(OWNER);
        adapter.setRate(address(usdc), address(eurc), _rate);
        adapter.setEnabled(address(usdc), address(eurc), true);
        vm.stopPrank();
    }

    function test_swap_happyPath_1to0p925() public {
        _enableUsdcEurc(0.925e18);

        // Entrypoint pattern: pre-transfer sellAmount to the adapter.
        uint256 sellAmount = 100 * 10**6; // 100 USDC
        usdc.mint(address(adapter), sellAmount); // simulate the entrypoint transfer

        vm.prank(CALLER); // caller-of-record is the entrypoint, mocked here
        uint256 buyAmount = adapter.swapExactInput(
            address(usdc),
            address(eurc),
            sellAmount,
            92_000_000, // minBuyAmount 92 EURC
            RECIPIENT
        );

        // 100 * 0.925 = 92.5 EURC
        assertEq(buyAmount, 92_500_000, "buyAmount math");
        assertEq(eurc.balanceOf(RECIPIENT), 92_500_000, "recipient received");
    }

    function test_swap_reverts_pairDisabled_byDefault() public {
        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        vm.expectRevert(FxFixedRateSwapAdapter.PairDisabled.selector);
        adapter.swapExactInput(address(usdc), address(eurc), 100 * 10**6, 0, RECIPIENT);
    }

    function test_swap_reverts_pairDisabled_explicitOff() public {
        _enableUsdcEurc(0.925e18);
        vm.prank(OWNER);
        adapter.setEnabled(address(usdc), address(eurc), false);

        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        vm.expectRevert(FxFixedRateSwapAdapter.PairDisabled.selector);
        adapter.swapExactInput(address(usdc), address(eurc), 100 * 10**6, 0, RECIPIENT);
    }

    function test_swap_reverts_zeroRate() public {
        // Enable but no rate.
        vm.prank(OWNER);
        adapter.setEnabled(address(usdc), address(eurc), true);

        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        vm.expectRevert(FxFixedRateSwapAdapter.PairDisabled.selector);
        adapter.swapExactInput(address(usdc), address(eurc), 100 * 10**6, 0, RECIPIENT);
    }

    function test_swap_reverts_underMinBuy() public {
        _enableUsdcEurc(0.925e18);

        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(FxFixedRateSwapAdapter.UnderMinBuy.selector, 92_500_000, 95_000_000)
        );
        adapter.swapExactInput(address(usdc), address(eurc), 100 * 10**6, 95_000_000, RECIPIENT);
    }

    function test_swap_reverts_insufficientLiquidity() public {
        _enableUsdcEurc(0.925e18);

        // Empty out the buy-side treasury.
        uint256 startingEurc = eurc.balanceOf(address(adapter));
        vm.prank(OWNER);
        adapter.withdrawLiquidity(IERC20(address(eurc)), OWNER, startingEurc);
        assertEq(eurc.balanceOf(address(adapter)), 0);

        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        vm.expectRevert(
            abi.encodeWithSelector(FxFixedRateSwapAdapter.InsufficientLiquidity.selector, 92_500_000, 0)
        );
        adapter.swapExactInput(address(usdc), address(eurc), 100 * 10**6, 0, RECIPIENT);
    }

    function test_swap_reverts_zeroSell() public {
        _enableUsdcEurc(0.925e18);

        vm.prank(CALLER);
        vm.expectRevert(FxFixedRateSwapAdapter.ZeroSellAmount.selector);
        adapter.swapExactInput(address(usdc), address(eurc), 0, 0, RECIPIENT);
    }

    function test_swap_reverts_zeroRecipient() public {
        _enableUsdcEurc(0.925e18);

        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        vm.expectRevert(FxFixedRateSwapAdapter.ZeroAddress.selector);
        adapter.swapExactInput(address(usdc), address(eurc), 100 * 10**6, 0, address(0));
    }

    function test_swap_reverts_sellEqualsBuy() public {
        _enableUsdcEurc(0.925e18);

        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        vm.expectRevert(FxFixedRateSwapAdapter.SellEqualsBuy.selector);
        adapter.swapExactInput(address(usdc), address(usdc), 100 * 10**6, 0, RECIPIENT);
    }

    function test_swap_bidirectional() public {
        // Set both directions with inverse-ish rates.
        vm.startPrank(OWNER);
        adapter.setRate(address(usdc), address(eurc), 0.925e18);
        adapter.setEnabled(address(usdc), address(eurc), true);
        adapter.setRate(address(eurc), address(usdc), 1.0811e18);
        adapter.setEnabled(address(eurc), address(usdc), true);
        vm.stopPrank();

        // USDC → EURC.
        usdc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        adapter.swapExactInput(address(usdc), address(eurc), 100 * 10**6, 0, RECIPIENT);
        assertEq(eurc.balanceOf(RECIPIENT), 92_500_000);

        // EURC → USDC.
        eurc.mint(address(adapter), 100 * 10**6);
        vm.prank(CALLER);
        adapter.swapExactInput(address(eurc), address(usdc), 100 * 10**6, 0, RECIPIENT);
        assertEq(usdc.balanceOf(RECIPIENT), 108_110_000);
    }
}
