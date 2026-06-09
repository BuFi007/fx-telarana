// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FxLiquidationEngine} from "../../src/perp/FxLiquidationEngine.sol";

/// @notice Minimal margin stub — `liquidate()` only reads `marginOf` (and skips
///         the reward transfer when it is 0).
contract StubMargin {
    function marginOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Harness isolating the flag-management logic from the full perp stack.
///         `liq` controls the verified health check; `closeHeals` lets the
///         simulated close flip the position to healthy.
contract FlagHarness is FxLiquidationEngine {
    bool public liq;
    bool public closeHeals;

    constructor(address health, address ch, address margin, address admin)
        FxLiquidationEngine(health, ch, margin, admin)
    {}

    function setLiquidatable(bool v) external {
        liq = v;
    }

    function setCloseHeals(bool v) external {
        closeHeals = v;
    }

    function _healthIsLiquidatableVerified(bytes32, address) internal view override returns (bool) {
        return liq;
    }

    function _clearinghouseLiquidatePosition(bytes32, address, uint256)
        internal
        override
        returns (uint256, int256, uint256)
    {
        if (closeHeals) liq = false; // a full close heals the position
        return (0, 0, 0);
    }
}

/// @notice F-12 — a partial liquidation must NOT reset the flag while the
///         position is still liquidatable (which would re-arm `flagDelay` and
///         let a griefer block real liquidation by closing dust each round).
contract FxLiquidationFlagResetTest is Test {
    FlagHarness internal h;
    StubMargin internal margin;

    bytes32 internal constant MARKET_ID = keccak256("FX-PERP:EURC/USDC");
    address internal constant TRADER = address(0x7AADE5);

    function setUp() public {
        margin = new StubMargin();
        h = new FlagHarness(address(0x4EA17), address(0xC1EA), address(margin), address(this));
        h.configureLiquidation(
            FxLiquidationEngine.LiquidationConfig({bountyBps: 0, bountyCap: 0, flagDelay: 60})
        );
    }

    function test_partialLiquidation_keepsFlagWhenStillUnhealthy() public {
        h.setLiquidatable(true);
        h.flagAccount(MARKET_ID, TRADER);
        uint256 ts = h.flaggedAt(MARKET_ID, TRADER);
        assertGt(ts, 0, "flagged");

        vm.warp(block.timestamp + 61); // past flagDelay

        h.setCloseHeals(false); // dust close, still liquidatable after
        h.liquidate(MARKET_ID, TRADER, 1);

        // F-12: flag preserved — pre-fix this was deleted unconditionally.
        assertEq(h.flaggedAt(MARKET_ID, TRADER), ts, "flag preserved across partial close");
    }

    function test_fullLiquidation_clearsFlagWhenHealthy() public {
        h.setLiquidatable(true);
        h.flagAccount(MARKET_ID, TRADER);
        assertGt(h.flaggedAt(MARKET_ID, TRADER), 0, "flagged");

        vm.warp(block.timestamp + 61);

        h.setCloseHeals(true); // full close heals the position
        h.liquidate(MARKET_ID, TRADER, type(uint256).max);

        assertEq(h.flaggedAt(MARKET_ID, TRADER), 0, "flag cleared once healthy");
    }
}
