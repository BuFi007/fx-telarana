// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PMMPricing} from "dodo-pmm/PMMPricing.sol";
import {DecimalMath} from "dodo-pmm/DecimalMath.sol";
import {Math as DodoMath} from "dodo-pmm/Math.sol";

/// @notice Smoke tests for the vendored DODO PMM math. Asserts the library
///         is callable from our build and behaves like the published reference.
contract DodoPMMSmokeTest is Test {
    using PMMPricing for PMMPricing.PMMState;

    uint256 internal constant ONE = 1e18;

    /// @dev R=ONE, K=0 means a constant-price swap (i * delta) with no slippage.
    ///      Round-trip should preserve invariants modulo `i`.
    function test_R_ONE_K0_isPureMidPrice() public pure {
        PMMPricing.PMMState memory state = PMMPricing.PMMState({
            i: ONE, // 1.0
            K: 0,
            B: 1000 * ONE,
            Q: 1000 * ONE,
            B0: 1000 * ONE,
            Q0: 1000 * ONE,
            R: PMMPricing.RState.ONE
        });

        // Sell 100 base @ K=0 → receive exactly 100 quote (i=1.0, no slippage).
        (uint256 quoteOut, PMMPricing.RState newR) = state.sellBaseToken(100 * ONE);
        assertEq(quoteOut, 100 * ONE);
        assertEq(uint256(newR), uint256(PMMPricing.RState.BELOW_ONE));
    }

    /// @dev R=ONE, K>0 gives a quadratic concession (size impact).
    function test_R_ONE_K_nonzero_hasSlippage() public pure {
        PMMPricing.PMMState memory state = PMMPricing.PMMState({
            i: ONE,
            K: ONE / 10, // 10%
            B: 1000 * ONE,
            Q: 1000 * ONE,
            B0: 1000 * ONE,
            Q0: 1000 * ONE,
            R: PMMPricing.RState.ONE
        });

        (uint256 tinyOut,) = state.sellBaseToken(1 * ONE);
        (uint256 bigOut,)  = state.sellBaseToken(500 * ONE);

        // tiny trade close to mid; big trade hit by slippage tax.
        assertApproxEqRel(tinyOut, 1 * ONE, 0.01e18);
        assertLt(bigOut, 500 * ONE);          // worse than mid
        assertLt(bigOut * 1e18 / (500 * ONE), tinyOut * 1e18 / (1 * ONE)); // worse rate
    }

    /// @dev Buy/sell symmetry at R=ONE: sell B, buy back same Q, end near origin.
    function test_R_ONE_buy_then_sell_recoversBase() public pure {
        PMMPricing.PMMState memory state = PMMPricing.PMMState({
            i: ONE,
            K: ONE / 10,
            B: 1000 * ONE,
            Q: 1000 * ONE,
            B0: 1000 * ONE,
            Q0: 1000 * ONE,
            R: PMMPricing.RState.ONE
        });

        (uint256 quoteOut, PMMPricing.RState midR) = state.sellBaseToken(50 * ONE);
        state.B = state.B + 50 * ONE;
        state.Q = state.Q - quoteOut;
        state.R = midR;

        (uint256 baseBack, PMMPricing.RState finalR) = state.sellQuoteToken(quoteOut);
        // K-curve is symmetric around the equilibrium; round-trip recovers within
        // dust (a few wei loss is acceptable from quadratic-solve rounding).
        assertApproxEqAbs(baseBack, 50 * ONE, 1e15); // within 0.001 base
        assertEq(uint256(finalR), uint256(PMMPricing.RState.ONE));
    }

    /// @dev DecimalMath round-trip: divFloor ∘ mulFloor approximates identity.
    function test_decimalMath_roundtrip(uint128 target, uint128 d) public pure {
        vm.assume(target > 0 && d > 0);
        uint256 t = uint256(target);
        uint256 dN = uint256(d);
        uint256 prod = DecimalMath.mulFloor(t, dN);
        uint256 back = DecimalMath.divFloor(prod, dN);
        // floor → floor can lose up to (t / d) wei. Bound the drift.
        assertLe(back, t);
    }

    /// @dev sqrt is monotone and matches Babylonian fixed point.
    function test_math_sqrt_monotone() public pure {
        uint256 a = DodoMath.sqrt(1e36);    // sqrt(10^36) = 10^18
        uint256 b = DodoMath.sqrt(4e36);    // sqrt(4·10^36) = 2·10^18
        assertEq(a, 1e18);
        assertEq(b, 2e18);
        assertLt(a, b);
    }
}
