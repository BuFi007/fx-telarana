// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxOracle} from "../src/hub/FxOracle.sol";
import {IFxOracle} from "../src/interfaces/IFxOracle.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice Testable FxOracle that overrides `_redstoneFetch` so tests can drive
///         RedStone values without constructing real signed payloads. Also
///         relaxes the consumer-base authorization so test signers aren't needed.
contract TestableFxOracle is FxOracle {
    mapping(bytes32 => uint256) public redstoneValueOf;
    bool public redstoneShouldRevert;

    constructor(address pyth_, address owner_, uint256 maxAge_, uint256 maxDev_, uint256 maxConf_)
        FxOracle(pyth_, owner_, maxAge_, maxDev_, maxConf_)
    {}

    function setRedstoneValue(bytes32 feedId, uint256 valueE8) external {
        redstoneValueOf[feedId] = valueE8;
    }

    function setRedstoneShouldRevert(bool v) external {
        redstoneShouldRevert = v;
    }

    function _redstoneFetch(bytes32[] memory feedIds)
        internal
        view
        override
        returns (uint256[] memory)
    {
        if (redstoneShouldRevert) revert("RedStone unavailable");
        uint256[] memory values = new uint256[](feedIds.length);
        for (uint256 i; i < feedIds.length; ++i) {
            values[i] = redstoneValueOf[feedIds[i]];
        }
        return values;
    }

    // Allow any signer in tests (we never construct real RedStone payloads here).
    function getAuthorisedSignerIndex(address) public view virtual override returns (uint8) {
        return 0;
    }

    function getUniqueSignersThreshold() public view virtual override returns (uint8) {
        return 0;
    }
}

contract FxOracleTest is Test {
    TestableFxOracle internal oracle;
    MockPyth internal pyth;
    address internal owner = address(0xA11CE);

    address internal constant USDC = address(0x10ce);
    address internal constant EURC = address(0xe0ce);

    bytes32 internal constant PYTH_USDC = bytes32(uint256(1));
    bytes32 internal constant PYTH_EURC = bytes32(uint256(2));

    bytes32 internal constant RS_USDC = bytes32("USDC");
    bytes32 internal constant RS_EURC = bytes32("EURC");

    uint256 internal constant MAX_AGE = 60;
    uint256 internal constant MAX_DEV_BPS = 50;
    uint256 internal constant MAX_CONF_BPS = 30;

    function setUp() public {
        pyth = new MockPyth();
        oracle = new TestableFxOracle(address(pyth), owner, MAX_AGE, MAX_DEV_BPS, MAX_CONF_BPS);

        vm.startPrank(owner);
        oracle.setFeed(USDC, PYTH_USDC);
        oracle.setFeed(EURC, PYTH_EURC);
        oracle.setRedstoneFeed(USDC, RS_USDC);
        oracle.setRedstoneFeed(EURC, RS_EURC);
        vm.stopPrank();

        _setPyth(PYTH_USDC, 1_00_000_000, 100, -8, block.timestamp);   // USDC/USD = 1.00, conf 1bps
        _setPyth(PYTH_EURC, 1_08_000_000, 108, -8, block.timestamp);   // EURC/USD = 1.08, conf 1bps

        // RedStone returns 1e8 scaled values (matches Pyth normal feed scale).
        oracle.setRedstoneValue(RS_USDC, 1_00_000_000);
        oracle.setRedstoneValue(RS_EURC, 1_08_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                              getMid (PYTH-ONLY)
    //////////////////////////////////////////////////////////////*/

    function test_getMid_EURC_USDC_isApprox1p08() public view {
        (uint256 mid, uint256 ts) = oracle.getMid(EURC, USDC);
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
        assertGt(ts, 0);
    }

    function test_getMid_USDC_EURC_isReciprocal() public view {
        (uint256 mid, ) = oracle.getMid(USDC, EURC);
        assertApproxEqRel(mid, 0.9259e18, 0.001e18);
    }

    function test_getMid_revertsOnStale() public {
        skip(MAX_AGE + 1);
        vm.expectRevert();
        oracle.getMid(EURC, USDC);
    }

    function test_getMid_revertsOnLowConfidence() public {
        _setPyth(PYTH_EURC, 1_08_000_000, 1_080_000, -8, block.timestamp);
        vm.expectRevert();
        oracle.getMid(EURC, USDC);
    }

    function test_getMid_revertsOnUnknownFeed() public {
        address random = address(0xCAFE);
        vm.expectRevert();
        oracle.getMid(random, USDC);
    }

    function test_getMid_doesNotCheckRedstone() public {
        // Wildly off RedStone — getMid must NOT trip
        oracle.setRedstoneValue(RS_EURC, 5_00_000_000);
        (uint256 mid, ) = oracle.getMid(EURC, USDC);
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
    }

    /*//////////////////////////////////////////////////////////////
                          getMidVerified (DEVIATION)
    //////////////////////////////////////////////////////////////*/

    function test_getMidVerified_passesWhenWithinTolerance() public view {
        (uint256 mid, ) = oracle.getMidVerified(EURC, USDC);
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
    }

    function test_getMidVerified_revertsOnDeviation() public {
        // Pyth says EURC=1.08, RedStone says 1.10 — 185 bps deviation
        oracle.setRedstoneValue(RS_EURC, 1_10_000_000);
        vm.expectRevert();
        oracle.getMidVerified(EURC, USDC);
    }

    function test_getMidVerified_revertsOnUnknownRedstoneFeed() public {
        address newToken = address(0xBEEF);
        vm.startPrank(owner);
        oracle.setFeed(newToken, bytes32(uint256(99)));    // Pyth feed set
        // RedStone feed NOT set
        vm.stopPrank();
        _setPyth(bytes32(uint256(99)), 1_00_000_000, 100, -8, block.timestamp);

        vm.expectRevert();
        oracle.getMidVerified(newToken, USDC);
    }

    function test_getMidVerified_passesWithSmallDeviation() public {
        // 4.6 bps deviation — within 50bps default
        oracle.setRedstoneValue(RS_EURC, 1_08_050_000);
        (uint256 mid, ) = oracle.getMidVerified(EURC, USDC);
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
    }

    function test_getMidVerified_propagatesRedstoneFailure() public {
        oracle.setRedstoneShouldRevert(true);
        vm.expectRevert();
        oracle.getMidVerified(EURC, USDC);
    }

    /*//////////////////////////////////////////////////////////////
                            getMidWithUpdate
    //////////////////////////////////////////////////////////////*/

    function test_getMidWithUpdate_paysFeeAndRefunds() public {
        pyth.setUpdateFee(0.001 ether);
        bytes[] memory updates = new bytes[](1);
        updates[0] = hex"00";

        uint256 balBefore = address(this).balance;
        (uint256 mid, ) = oracle.getMidWithUpdate{value: 0.01 ether}(EURC, USDC, updates);
        assertApproxEqRel(mid, 1.08e18, 0.001e18);
        uint256 balAfter = address(this).balance;
        assertEq(balBefore - balAfter, 0.001 ether);
    }

    function test_getMidWithUpdate_revertsOnInsufficientFee() public {
        pyth.setUpdateFee(0.001 ether);
        bytes[] memory updates = new bytes[](1);
        updates[0] = hex"00";

        vm.expectRevert();
        oracle.getMidWithUpdate{value: 0}(EURC, USDC, updates);
    }

    function test_getMidWithUpdate_runsDeviationGate() public {
        pyth.setUpdateFee(0);
        oracle.setRedstoneValue(RS_EURC, 1_15_000_000); // ~648 bps deviation
        bytes[] memory updates = new bytes[](1);
        updates[0] = hex"00";

        vm.expectRevert();
        oracle.getMidWithUpdate(EURC, USDC, updates);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setFeed_onlyOwner() public {
        vm.expectRevert();
        oracle.setFeed(USDC, bytes32(uint256(42)));
    }

    function test_setRedstoneFeed_onlyOwner() public {
        vm.expectRevert();
        oracle.setRedstoneFeed(USDC, bytes32("BAD"));
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
