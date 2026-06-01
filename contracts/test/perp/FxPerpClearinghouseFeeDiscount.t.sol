// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxFundingEngine} from "../../src/perp/FxFundingEngine.sol";
import {FxMarginAccount} from "../../src/perp/FxMarginAccount.sol";
import {FxPerpClearinghouse} from "../../src/perp/FxPerpClearinghouse.sol";
import {KawaiiFeeDiscount} from "../../src/perp/KawaiiFeeDiscount.sol";
import {IFeeDiscount} from "../../src/perp/interfaces/IFeeDiscount.sol";
import {IFxPerpClearinghouse} from "../../src/perp/interfaces/IFxPerpClearinghouse.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

// Reuse the harness + oracle mock already defined in the stack test.
import {FxPerpClearinghouseTestHarness, MockPerpOracle} from "./FxPerpStack.t.sol";

/// @notice Discount source that always reverts, to prove the clearinghouse
///         fails safe to full fee and never blocks a trade.
contract RevertingDiscount is IFeeDiscount {
    function discountBps(address) external pure returns (uint16) {
        revert("boom");
    }
}

/// @notice Discount source that returns above the 5000 cap, to prove the
///         clearinghouse clamps.
contract OverCapDiscount is IFeeDiscount {
    function discountBps(address) external pure returns (uint16) {
        return 9000;
    }
}

contract MockKawaiiErc721 {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to] += 1;
    }
}

contract FxPerpClearinghouseFeeDiscountTest is Test {
    address internal constant ADMIN = address(0xAD);
    address internal constant KEEPER = address(0xCAFE);
    address internal constant TRADER = address(0x7AdE);

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockPerpOracle internal oracle;
    FxMarginAccount internal margin;
    FxFundingEngine internal funding;
    FxPerpClearinghouseTestHarness internal clearinghouse;

    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");
    uint256 internal constant PRICE_1_10 = 1.1e18;

    // size 10e18 @ 1.1 -> notional 11e6 (6 dp); fee 5 bps -> 5_500 full fee.
    uint256 internal constant FULL_FEE = 5_500;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 18);
        oracle = new MockPerpOracle();
        oracle.setMid(address(eurc), address(usdc), PRICE_1_10);

        vm.startPrank(ADMIN);
        margin = new FxMarginAccount(address(usdc), ADMIN);
        clearinghouse = new FxPerpClearinghouseTestHarness(address(usdc), address(oracle), address(margin), ADMIN);
        funding = new FxFundingEngine(address(clearinghouse), address(margin), ADMIN);

        clearinghouse.setFundingEngine(address(funding));
        margin.setFundingSettlementHook(address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(clearinghouse));
        margin.grantRole(margin.CLEARINGHOUSE_ROLE(), address(funding));
        clearinghouse.grantRole(clearinghouse.EXECUTOR_ROLE(), KEEPER);

        clearinghouse.configureMarket(MARKET_ID, _marketConfig());
        funding.configureFunding(
            MARKET_ID,
            FxFundingEngine.FundingConfig({enabled: true, maxFundingRateBpsPerSecond: 1, fundingVelocityBps: 1_000})
        );
        vm.stopPrank();

        _seedProtocolLiquidity(1_000e6);
        _deposit(TRADER, 100e6);
    }

    // --- backwards compat: no discount source set ---

    function test_unsetDiscountChargesFullFee() public {
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, FULL_FEE);

        // Full fee 5_500 deducted from 100e6 margin.
        assertEq(margin.marginOf(TRADER), 100e6 - FULL_FEE, "full fee charged");
        (uint256 quoted,) = clearinghouse.quoteFee(MARKET_ID, TRADER, 10e18);
        assertEq(quoted, FULL_FEE, "quoteFee full");
    }

    // --- discount set: discounted fee charged + maxFee vs discounted ---

    function test_holderGets10PercentOff() public {
        MockKawaiiErc721 nft = new MockKawaiiErc721();
        nft.mint(TRADER);
        KawaiiFeeDiscount disc = new KawaiiFeeDiscount(address(nft), false, 0, ADMIN);
        vm.prank(ADMIN);
        clearinghouse.setFeeDiscount(address(disc));

        uint256 expected = FULL_FEE * 9000 / 10_000; // 10% off
        (uint256 quoted,) = clearinghouse.quoteFee(MARKET_ID, TRADER, 10e18);
        assertEq(quoted, expected, "quoteFee discounted 10%");

        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, expected);
        assertEq(margin.marginOf(TRADER), 100e6 - expected, "discounted fee charged");
    }

    function test_vip5Gets50PercentOff() public {
        KawaiiFeeDiscount disc = new KawaiiFeeDiscount(address(0), false, 0, ADMIN);
        vm.prank(ADMIN);
        disc.setDiscount(TRADER, 5000); // VIP5
        vm.prank(ADMIN);
        clearinghouse.setFeeDiscount(address(disc));

        uint256 expected = FULL_FEE / 2;
        (uint256 quoted,) = clearinghouse.quoteFee(MARKET_ID, TRADER, 10e18);
        assertEq(quoted, expected, "50% off");

        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, expected);
        assertEq(margin.marginOf(TRADER), 100e6 - expected, "VIP5 fee charged");
    }

    function test_maxFeeComparedAgainstDiscountedFee() public {
        KawaiiFeeDiscount disc = new KawaiiFeeDiscount(address(0), false, 0, ADMIN);
        vm.prank(ADMIN);
        disc.setDiscount(TRADER, 5000);
        vm.prank(ADMIN);
        clearinghouse.setFeeDiscount(address(disc));

        uint256 discounted = FULL_FEE / 2; // 2_750
        // maxFee below the FULL fee but >= the discounted fee: must succeed,
        // proving the comparison uses the discounted value.
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, discounted);
        assertEq(margin.marginOf(TRADER), 100e6 - discounted);
    }

    function test_maxFeeStillEnforcedOnDiscountedFee() public {
        KawaiiFeeDiscount disc = new KawaiiFeeDiscount(address(0), false, 0, ADMIN);
        vm.prank(ADMIN);
        disc.setDiscount(TRADER, 5000);
        vm.prank(ADMIN);
        clearinghouse.setFeeDiscount(address(disc));

        uint256 discounted = FULL_FEE / 2; // 2_750
        vm.expectRevert(
            abi.encodeWithSelector(FxPerpClearinghouse.SlippageFeeExceeded.selector, discounted, discounted - 1)
        );
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, discounted - 1);
    }

    function test_overCapDiscountClampedTo50Percent() public {
        OverCapDiscount disc = new OverCapDiscount(); // returns 9000
        vm.prank(ADMIN);
        clearinghouse.setFeeDiscount(address(disc));

        uint256 expected = FULL_FEE / 2; // clamped to 5000 -> 50%
        (uint256 quoted,) = clearinghouse.quoteFee(MARKET_ID, TRADER, 10e18);
        assertEq(quoted, expected, "clamped to 50%");
    }

    // --- reverting discount source: fail-safe to full fee, no trade block ---

    function test_revertingDiscountFallsBackToFullFee() public {
        RevertingDiscount disc = new RevertingDiscount();
        vm.prank(ADMIN);
        clearinghouse.setFeeDiscount(address(disc));

        (uint256 quoted,) = clearinghouse.quoteFee(MARKET_ID, TRADER, 10e18);
        assertEq(quoted, FULL_FEE, "fallback full fee on revert");

        // Trade still goes through (not blocked) at the full fee.
        vm.prank(KEEPER);
        clearinghouse.openOrIncrease(MARKET_ID, TRADER, 10e18, FULL_FEE);
        assertEq(margin.marginOf(TRADER), 100e6 - FULL_FEE, "full fee charged, trade not blocked");
    }

    // --- access control on setter ---

    function test_onlyAdminSetsFeeDiscount() public {
        KawaiiFeeDiscount disc = new KawaiiFeeDiscount(address(0), false, 0, ADMIN);
        vm.prank(KEEPER);
        vm.expectRevert();
        clearinghouse.setFeeDiscount(address(disc));
    }

    function test_setFeeDiscountRejectsNonContract() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(FxPerpClearinghouse.InvalidFeeDiscount.selector, address(0xdead)));
        clearinghouse.setFeeDiscount(address(0xdead));
    }

    function test_zeroAddressDisablesDiscount() public {
        KawaiiFeeDiscount disc = new KawaiiFeeDiscount(address(0), false, 0, ADMIN);
        vm.prank(ADMIN);
        disc.setDiscount(TRADER, 5000);
        vm.startPrank(ADMIN);
        clearinghouse.setFeeDiscount(address(disc));
        clearinghouse.setFeeDiscount(address(0)); // disable again
        vm.stopPrank();

        (uint256 quoted,) = clearinghouse.quoteFee(MARKET_ID, TRADER, 10e18);
        assertEq(quoted, FULL_FEE, "disabled -> full fee");
    }

    // --- helpers ---

    function _marketConfig() internal view returns (IFxPerpClearinghouse.MarketConfig memory) {
        return IFxPerpClearinghouse.MarketConfig({
            baseToken: address(eurc),
            enabled: true,
            initialMarginBps: 500,
            maintenanceMarginBps: 300,
            tradingFeeBps: 5,
            maxLeverageBps: 200_000,
            maxOpenInterestUsd: 1_000_000e6,
            maxSkewUsd: 1_000_000e6
        });
    }

    function _deposit(address trader, uint256 amount) internal {
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(margin), amount);
        margin.depositMargin(trader, amount);
        vm.stopPrank();
    }

    function _seedProtocolLiquidity(uint256 amount) internal {
        usdc.mint(ADMIN, amount);
        vm.startPrank(ADMIN);
        usdc.approve(address(margin), amount);
        margin.depositProtocolLiquidity(amount);
        vm.stopPrank();
    }
}
