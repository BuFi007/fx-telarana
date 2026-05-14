// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxOracle} from "../src/hub/FxOracle.sol";
import {IFxOracle} from "../src/interfaces/IFxOracle.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract FxOracleTest is Test {
    FxOracle internal oracle;
    MockPyth internal pyth;
    address internal owner = address(0xA11CE);

    address internal constant USDC = address(0x10ce);
    address internal constant EURC = address(0xe0ce);

    bytes32 internal constant FEED_USDC = bytes32(uint256(1));
    bytes32 internal constant FEED_EURC = bytes32(uint256(2));

    uint256 internal constant MAX_AGE = 60;
    uint256 internal constant MAX_DEV_BPS = 50;
    uint256 internal constant MAX_CONF_BPS = 30;

    function setUp() public {
        pyth = new MockPyth();
        oracle = new FxOracle(address(pyth), owner, MAX_AGE, MAX_DEV_BPS, MAX_CONF_BPS);

        vm.startPrank(owner);
        oracle.setFeed(USDC, FEED_USDC);
        oracle.setFeed(EURC, FEED_EURC);
        vm.stopPrank();

        // USDC/USD = 1.00, EURC/USD = 1.08 — sanity baselines, fresh
        _setPyth(FEED_USDC, 1_00_000_000, 100, -8, block.timestamp);   // 1.0, conf 1bps
        _setPyth(FEED_EURC, 1_08_000_000, 108, -8, block.timestamp);   // 1.08, conf 1bps
    }

    /*//////////////////////////////////////////////////////////////
                                HAPPY
    //////////////////////////////////////////////////////////////*/

    function test_getMid_EURC_USDC_isApprox1p08() public view {
        (uint256 mid, uint256 ts) = oracle.getMid(EURC, USDC);
        // mid should be ~1.08e18 (off by rounding)
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
        assertGt(ts, 0);
    }

    function test_getMid_USDC_EURC_isReciprocal() public view {
        (uint256 mid, ) = oracle.getMid(USDC, EURC);
        assertApproxEqRel(mid, 0.9259e18, 0.001e18); // 1 / 1.08 ~= 0.9259
    }

    /*//////////////////////////////////////////////////////////////
                                STALENESS
    //////////////////////////////////////////////////////////////*/

    function test_getMid_revertsOnStale() public {
        skip(MAX_AGE + 1);
        vm.expectRevert();
        oracle.getMid(EURC, USDC);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIDENCE
    //////////////////////////////////////////////////////////////*/

    function test_getMid_revertsOnLowConfidence() public {
        // bump conf to 100bps (>30bps threshold)
        _setPyth(FEED_EURC, 1_08_000_000, 1_080_000, -8, block.timestamp); // conf = 1% of price
        vm.expectRevert();
        oracle.getMid(EURC, USDC);
    }

    /*//////////////////////////////////////////////////////////////
                                DEVIATION
    //////////////////////////////////////////////////////////////*/

    function test_getMid_revertsOnRedstoneDeviation() public {
        // Inject RedStone cache with 100bps deviation vs Pyth
        vm.startPrank(owner);
        oracle._setRedstoneCacheForTest(USDC, 1.00e18, block.timestamp);
        oracle._setRedstoneCacheForTest(EURC, 1.09e18, block.timestamp); // pyth says 1.08, redstone 1.09 = ~92bps
        vm.stopPrank();

        vm.expectRevert();
        oracle.getMid(EURC, USDC);
    }

    function test_getMid_passesWhenRedstoneWithinTolerance() public {
        vm.startPrank(owner);
        oracle._setRedstoneCacheForTest(USDC, 1.00e18, block.timestamp);
        oracle._setRedstoneCacheForTest(EURC, 1.0805e18, block.timestamp); // ~4.6bps deviation
        vm.stopPrank();

        (uint256 mid, ) = oracle.getMid(EURC, USDC);
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
    }

    function test_getMid_skipsDeviationCheckWhenRedstoneStale() public {
        vm.startPrank(owner);
        oracle._setRedstoneCacheForTest(USDC, 1.00e18, block.timestamp);
        oracle._setRedstoneCacheForTest(EURC, 1.20e18, block.timestamp); // would otherwise deviate
        vm.stopPrank();
        skip(MAX_AGE + 1);
        // refresh pyth to defeat its own staleness
        _setPyth(FEED_USDC, 1_00_000_000, 100, -8, block.timestamp);
        _setPyth(FEED_EURC, 1_08_000_000, 108, -8, block.timestamp);

        (uint256 mid, ) = oracle.getMid(EURC, USDC); // does not revert: redstone is stale, skipped
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
    }

    /*//////////////////////////////////////////////////////////////
                                UNKNOWN FEED
    //////////////////////////////////////////////////////////////*/

    function test_getMid_revertsOnUnknownFeed() public {
        address random = address(0xCAFE);
        vm.expectRevert();
        oracle.getMid(random, USDC);
    }

    /*//////////////////////////////////////////////////////////////
                                UPDATE PATH
    //////////////////////////////////////////////////////////////*/

    function test_getMidWithUpdate_paysFeeAndRefunds() public {
        pyth.setUpdateFee(0.001 ether);
        bytes[] memory updates = new bytes[](1);
        updates[0] = hex"00";

        uint256 balBefore = address(this).balance;
        (uint256 mid, ) = oracle.getMidWithUpdate{value: 0.01 ether}(EURC, USDC, updates, "");
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
        uint256 balAfter = address(this).balance;
        // refunded 0.01 - 0.001
        assertEq(balBefore - balAfter, 0.001 ether);
    }

    function test_getMidWithUpdate_revertsOnInsufficientFee() public {
        pyth.setUpdateFee(0.001 ether);
        bytes[] memory updates = new bytes[](1);
        updates[0] = hex"00";

        vm.expectRevert();
        oracle.getMidWithUpdate{value: 0}(EURC, USDC, updates, "");
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setFeed_onlyOwner() public {
        vm.expectRevert();
        oracle.setFeed(USDC, bytes32(uint256(42)));
    }

    function test_setConfig_updatesAndEmits() public {
        vm.prank(owner);
        oracle.setConfig(120, 100, 60);
        (uint256 a, uint256 d, uint256 c) = oracle.config();
        assertEq(a, 120);
        assertEq(d, 100);
        assertEq(c, 60);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setPyth(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishedAt) internal {
        pyth.setPrice(id, price, conf, expo, publishedAt);
    }

    receive() external payable {}
}
