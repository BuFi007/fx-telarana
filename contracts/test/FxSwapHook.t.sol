// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockFxVault} from "./mocks/MockFxVault.sol";
import {FxOracle} from "../src/hub/FxOracle.sol";

contract FxSwapHookTest is Test {
    FxSwapHook internal hook;
    FxOracle   internal oracle;
    MockPyth   internal pyth;
    MockFxVault internal vault;
    MockERC20  internal token0;
    MockERC20  internal token1;
    address    internal poolManager = address(0x1111);
    address    internal registry    = address(0x3333);
    address    internal owner       = address(0xA11CE);
    address    internal alice       = address(0xCAFE);

    bytes32 internal constant PYTH_T0 = bytes32(uint256(1));
    bytes32 internal constant PYTH_T1 = bytes32(uint256(2));

    function setUp() public {
        // Deploy tokens with deterministic ordering: token0 address < token1 address
        // The mock tokens are deployed in sequence so the first will have a lower address.
        MockERC20 a = new MockERC20("A", "A", 6);
        MockERC20 b = new MockERC20("B", "B", 6);
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }

        pyth = new MockPyth();
        oracle = new FxOracle(address(pyth), owner, 60, 50, 30);
        vm.startPrank(owner);
        oracle.setFeed(address(token0), PYTH_T0);
        oracle.setFeed(address(token1), PYTH_T1);
        vm.stopPrank();

        // token0 = token1 = $1.00, so mid(t0,t1) = 1.0
        pyth.setPrice(PYTH_T0, 1_00_000_000, 100, -8, block.timestamp);
        pyth.setPrice(PYTH_T1, 1_00_000_000, 100, -8, block.timestamp);

        // Vault-backed refactor: liquidity reserves now live in the shared vault.
        // The hook reads them via `_vaultReserve` so unit tests must supply a real
        // vault contract (a non-contract placeholder reverts on the staticcall).
        // asset = token0 → `_vaultReserve(token0)` reads `juniorUsdc()`.
        vault = new MockFxVault(address(token0));

        hook = new FxSwapHook(
            poolManager,
            address(oracle),
            registry,
            owner,
            address(token0),
            address(token1),
            address(0x4444),  // mock morpho — unused at hotReservePct = 10_000
            address(vault)    // vault-backed reserves (replaces deprecated deposit() custody)
        );

        // Use 100% hot reserves so these standalone unit tests don't touch
        // the (mocked) Morpho/registry. Phase 2.6 rehypothecation is exercised
        // in fork-based tests.
        vm.prank(owner);
        hook.setHotReservePct(10_000);

        // Fund alice with both tokens
        token0.mint(alice, 1_000_000_000); // 1000 token0
        token1.mint(alice, 1_000_000_000); // 1000 token1
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // Fund owner so they can perform the gated first deposit.
        // First-deposit is owner-only (Phase 2.7 codex-r12 patch) to prevent
        // an adversarial bootstrap that poisons B0/Q0 at an off-oracle ratio.
        token0.mint(owner, 1_000_000_000);
        token1.mint(owner, 1_000_000_000);
        vm.startPrank(owner);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Helper: owner bootstraps the PMM equilibrium with the given amounts.
    ///         Vault-backed refactor: the old `hook.deposit(...)` self-custody seed
    ///         is gone (it now reverts `UseVault`). We reproduce its exact effect by
    ///         (1) setting the vault's junior reserves to the seed amounts, then
    ///         (2) calling `sync()` so `baseTargetE18`/`quoteTargetE18` AND
    ///         `_vaultReserve(...)` equal those amounts — identical post-state to
    ///         what `deposit()` used to produce. Passing the exact expected target
    ///         (= the reserve) makes drift 0, so seeding always succeeds.
    function _seedAsOwner(uint256 amount0, uint256 amount1) internal {
        _seedVault(hook, vault, address(token0), amount0, address(token1), amount1);
    }

    /// @notice Vault-backed seed for an arbitrary hook/vault pair. Sets reserves on
    ///         the vault and syncs the hook's PMM targets to them.
    function _seedVault(
        FxSwapHook h,
        MockFxVault v,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB
    ) internal {
        v.setReserve(tokenA, amountA);
        v.setReserve(tokenB, amountB);
        // `sync()` reads _vaultReserve(TOKEN0)/(TOKEN1) and normalizes to 1e18.
        uint256 expBase  = _e18(h.TOKEN0() == tokenA ? amountA : amountB, MockERC20(h.TOKEN0()).decimals());
        uint256 expQuote = _e18(h.TOKEN1() == tokenB ? amountB : amountA, MockERC20(h.TOKEN1()).decimals());
        vm.prank(owner);
        h.sync(expBase, expQuote, 10_000);
    }

    /// @notice Mirror of the hook's `_rawToE18`: scale a raw token amount to 1e18.
    function _e18(uint256 amount, uint8 decimals) private pure returns (uint256) {
        return amount * (10 ** uint256(18 - decimals));
    }

    /*//////////////////////////////////////////////////////////////
                              PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function test_getHookPermissions_enablesExpectedFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertTrue(p.beforeSwapReturnDelta);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setSpreadBps_updatesAndEmits() public {
        vm.prank(owner);
        hook.setSpreadBps(50);
        assertEq(hook.spreadBps(), 50);
    }

    function test_setSpreadBps_onlyOwner() public {
        vm.expectRevert();
        hook.setSpreadBps(50);
    }

    function test_setSpreadBps_revertsAboveMax() public {
        uint16 maxBps = hook.MAX_SPREAD_BPS();
        vm.expectRevert();
        vm.prank(owner);
        hook.setSpreadBps(maxBps + 1);
    }

    function test_setKBps_updatesAndEmits() public {
        vm.prank(owner);
        hook.setKBps(200);
        assertEq(hook.kBps(), 200);
    }

    function test_setKBps_revertsAboveMax() public {
        uint16 maxK = hook.MAX_K_BPS();
        vm.expectRevert();
        vm.prank(owner);
        hook.setKBps(maxK + 1);
    }

    function test_constructor_setsDefaults() public {
        // Re-deploy to inspect untouched constructor defaults.
        FxSwapHook fresh = new FxSwapHook(
            poolManager, address(oracle), registry, owner,
            address(token0), address(token1), address(0x4444), address(0x5555)
        );
        assertEq(fresh.spreadBps(), fresh.DEFAULT_SPREAD_BPS());
        assertEq(fresh.kBps(), fresh.DEFAULT_K_BPS());
        assertEq(fresh.hotReservePct(), fresh.DEFAULT_HOT_RESERVE_PCT());
        assertEq(fresh.maxObservationChangeBps(), fresh.DEFAULT_MAX_OBSERVATION_CHANGE_BPS());
        assertEq(fresh.volatilitySpreadMultiplierBps(), fresh.DEFAULT_VOLATILITY_SPREAD_MULTIPLIER_BPS());
        assertEq(fresh.TOKEN0(), address(token0));
        assertEq(fresh.TOKEN1(), address(token1));
    }

    function test_constructor_revertsOnTokensUnsorted() public {
        vm.expectRevert();
        new FxSwapHook(poolManager, address(oracle), registry, owner, address(token1), address(token0), address(0x4444), address(0x5555));
    }

    function test_setHotReservePct_revertsAbove10k() public {
        vm.expectRevert();
        vm.prank(owner);
        hook.setHotReservePct(10_001);
    }

    function test_setHotReservePct_updatesAndEmits() public {
        vm.prank(owner);
        hook.setHotReservePct(2_000);
        assertEq(hook.hotReservePct(), 2_000);
    }

    function test_setOracleGuardrails_updatesDynamicFeeControls() public {
        vm.prank(owner);
        hook.setOracleGuardrails(250, 20_000);
        assertEq(hook.maxObservationChangeBps(), 250);
        assertEq(hook.volatilitySpreadMultiplierBps(), 20_000);
    }

    function test_setOracleGuardrails_revertsAboveCaps() public {
        uint16 maxObservationChange = hook.MAX_OBSERVATION_CHANGE_BPS();
        uint16 maxVolatilityMultiplier = hook.MAX_VOLATILITY_SPREAD_MULTIPLIER_BPS();

        vm.startPrank(owner);
        vm.expectRevert();
        hook.setOracleGuardrails(maxObservationChange + 1, 10_000);
        vm.expectRevert();
        hook.setOracleGuardrails(100, maxVolatilityMultiplier + 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                LP API
    //////////////////////////////////////////////////////////////*/

    // Vault-backed refactor: `deposit()` is permanently disabled — it reverts
    // `UseVault()` on its FIRST line. The legacy share-bootstrap / pro-rata /
    // first-deposit-ratio / target-growth mechanics it used to implement no
    // longer exist (liquidity lives in SharedFxVault, not the hook). The whole
    // obsolete set is collapsed into one assertion that the function is dead.
    function test_deposit_revertsUseVault() public {
        vm.expectRevert(FxSwapHook.UseVault.selector);
        vm.prank(owner);
        hook.deposit(1e6, 1e6);
    }

    // Vault-backed refactor: `redeem()` is likewise permanently disabled —
    // reverts `UseVault()` first thing. Pro-rata return / insufficient-shares /
    // target-shrink behaviors are gone (lenders exit via the vault). Collapsed
    // into a single dead-function assertion.
    function test_redeem_revertsUseVault() public {
        vm.expectRevert(FxSwapHook.UseVault.selector);
        vm.prank(alice);
        hook.redeem(1);
    }

    /*//////////////////////////////////////////////////////////////
                              PMM QUOTE
    //////////////////////////////////////////////////////////////*/

    function test_quote_atEquilibriumReturnsMidMinusSpread() public {
        _seedAsOwner(1_000_000_000, 1_000_000_000);

        // Trade is tiny relative to reserves → kImpact ≈ 0
        uint256 amountOut = hook.quote(1000, true);  // 1000 units in
        // Expect: amountOut ≈ 1000 * 1.0 * (1 - 30/10_000) = 997
        assertApproxEqAbs(amountOut, 997, 1);
    }

    function test_quote_largeTradeHasHigherSlippage() public {
        _seedAsOwner(1_000_000_000, 1_000_000_000);

        uint256 smallOut = hook.quote(1_000, true);              // tiny trade
        uint256 bigOut   = hook.quote(500_000_000, true);        // 50% of reserve

        // effective rate = out / in; should be worse for big trade
        // smallOut/1000 should be higher than bigOut/500_000_000
        uint256 smallRate = (smallOut * 1e18) / 1_000;
        uint256 bigRate   = (bigOut * 1e18) / 500_000_000;
        assertGt(smallRate, bigRate);
    }

    function test_quote_zeroKMeansNoSizeImpact() public {
        _seedAsOwner(1_000_000_000, 1_000_000_000);

        vm.prank(owner);
        hook.setKBps(0);

        uint256 smallOut = hook.quote(1_000, true);
        uint256 bigOut   = hook.quote(500_000_000, true);

        uint256 smallRate = (smallOut * 1e18) / 1_000;
        uint256 bigRate   = (bigOut * 1e18) / 500_000_000;
        assertApproxEqRel(smallRate, bigRate, 0.0001e18);
    }

    function test_recordOracleObservation_initializesCanonicalMid() public {
        (uint256 rawMid, uint256 truncatedMid, uint16 volatilityBps, uint16 effectiveSpread) =
            hook.recordOracleObservation();

        assertEq(rawMid, 1e18);
        assertEq(truncatedMid, 1e18);
        assertEq(volatilityBps, 0);
        assertEq(effectiveSpread, hook.DEFAULT_SPREAD_BPS());
        assertEq(hook.latestTruncatedMidE18(), 1e18);
        assertEq(hook.latestVolatilityBps(), 0);
        assertEq(hook.oracleObservationCardinality(), 1);
    }

    function test_previewOracleObservation_truncatesSuddenMoveAndWidensSpread() public {
        hook.recordOracleObservation();

        vm.warp(block.timestamp + 60);
        pyth.setPrice(PYTH_T0, 2_00_000_000, 100, -8, block.timestamp);

        (uint256 rawMid, uint256 truncatedMid, uint16 volatilityBps, uint16 effectiveSpread) =
            hook.previewOracleObservation();

        assertEq(rawMid, 2e18);
        assertEq(truncatedMid, 1_010_000_000_000_000_000);
        assertEq(volatilityBps, 100);
        assertEq(effectiveSpread, 130);
    }

    function test_quoteExactInput_usesTruncatedObservationAndVolatilitySpread() public {
        _seedAsOwner(1_000_000_000, 1_000_000_000);
        hook.recordOracleObservation();

        vm.warp(block.timestamp + 60);
        pyth.setPrice(PYTH_T0, 2_00_000_000, 100, -8, block.timestamp);

        (uint256 buyAmount, uint256 oraclePriceE18) = hook.quoteExactInput(address(token0), 1_000);
        assertEq(oraclePriceE18, 1_010_000_000_000_000_000);
        // 1000 * 1.01 less 130 bps spread, with tiny size impact.
        assertApproxEqAbs(buyAmount, 996, 1);
    }

    function test_quoteExactInput_scalesSixDecimalUsdcToEighteenDecimalJpyc() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 jpyc = new MockERC20("JPYC", "JPYC", 18);
        (FxSwapHook h, MockFxVault v) = _newHotOnlyHook(usdc, jpyc, 1_00_000_000, 640_000); // JPYC/USD = 0.0064

        // Vault-backed seed (replaces the old owner deposit): set reserves + sync.
        _depositSorted(h, v, address(usdc), 10_000e6, address(jpyc), 1_562_500e18);

        vm.prank(owner);
        h.setKBps(0);

        (uint256 buyAmount, uint256 oraclePriceE18) = h.quoteExactInput(address(usdc), 1e6);
        assertApproxEqRel(oraclePriceE18, 156.25e18, 0.0001e18);
        assertApproxEqRel(buyAmount, 155.78125e18, 0.0001e18); // 156.25 JPYC less 30 bps spread
    }

    function test_quoteExactInput_scalesSixDecimalUsdcToZeroDecimalKrw1() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 krw1 = new MockERC20("KRW1", "KRW1", 0);
        (FxSwapHook h, MockFxVault v) = _newHotOnlyHook(usdc, krw1, 1_00_000_000, 67_120); // KRW1/USD ~= 0.00067120

        // Vault-backed seed (replaces the old owner deposit): set reserves + sync.
        _depositSorted(h, v, address(usdc), 10_000e6, address(krw1), 14_898_689);

        vm.prank(owner);
        h.setKBps(0);

        (uint256 buyAmount, uint256 oraclePriceE18) = h.quoteExactInput(address(usdc), 1e6);
        assertApproxEqRel(oraclePriceE18, 1489.868891e18, 0.0001e18);
        assertEq(buyAmount, 1485); // 0-decimal output floors after spread
    }

    /*//////////////////////////////////////////////////////////////
                          DODO PMM (Phase 2.7 #2)
    //////////////////////////////////////////////////////////////*/

    // Was `test_deposit_firstDepositSeedsTargetsAtRatio`. Vault-backed refactor:
    // targets are no longer seeded by `deposit()`; they're set by `sync()` from
    // the vault reserves. The 1e18-normalization invariant the old test asserted
    // is preserved, so we keep it — re-pointed at the vault-backed seed path.
    function test_sync_seedsTargetsAtVaultReserveRatio() public {
        _seedAsOwner(200_000_000, 400_000_000);

        // Both tokens are 6-dec → targets are 1e18-normalized
        assertEq(hook.baseTargetE18(), 200_000_000 * 1e12);
        assertEq(hook.quoteTargetE18(), 400_000_000 * 1e12);
    }

    // Was `test_deposit_subsequentDepositGrowsTargetsProRata`. Vault-backed
    // refactor: there is no pro-rata target growth on deposit anymore — targets
    // track vault reserves and only move on `sync()`. Verify a re-sync after the
    // vault reserves grow snaps both targets up to the new reserves.
    function test_sync_growsTargetsWhenVaultReservesGrow() public {
        _seedAsOwner(1_000e6, 1_000e6);
        uint256 b0 = hook.baseTargetE18();
        uint256 q0 = hook.quoteTargetE18();

        // Vault reserves double, owner re-syncs → targets double.
        _seedAsOwner(2_000e6, 2_000e6);

        assertEq(hook.baseTargetE18(), b0 * 2);
        assertEq(hook.quoteTargetE18(), q0 * 2);
    }

    function test_quote_donationCannotDoSEitherDirection() public {
        // Codex-2.7 round 6 regression: a 1-wei reserve bump on either pair
        // token used to leave (B,Q,B0,Q0) outside the DODO regime preconditions,
        // underflowing _SolveQuadraticFunction and bricking one swap direction.
        // Patch: _normalizePmmState snaps targets to absorb it. Vault-backed:
        // reserves live in the vault, so the "donation" is a direct reserve bump
        // WITHOUT a re-sync (targets stay at the seeded value, reserves drift up).
        _seedAsOwner(1_000_000_000, 1_000_000_000);

        // Bump each side's vault reserve by 1 wei without re-syncing targets.
        vault.setReserve(address(token0), 1_000_000_000 + 1);
        vault.setReserve(address(token1), 1_000_000_000 + 1);

        // Both quote directions must still succeed (no underflow).
        uint256 out01 = hook.quote(10_000, true);
        uint256 out10 = hook.quote(10_000, false);
        assertGt(out01, 0, "donation DoS'd zeroForOne");
        assertGt(out10, 0, "donation DoS'd oneForZero");

        // Token-addressed view surface must also survive.
        (uint256 buy0,) = hook.quoteExactInput(address(token0), 10_000);
        (uint256 buy1,) = hook.quoteExactInput(address(token1), 10_000);
        assertGt(buy0, 0);
        assertGt(buy1, 0);
    }

    function test_sync_absorbsBalancedDonationIntoTargets() public {
        // Phase 2.7 ships DODO V2 reference behavior: donations are NOT
        // auto-absorbed on swap. Capturing yield/donations is keeper-driven
        // via public `sync()`, mirroring MagicLP's `_resetTargetAndR`.
        // Verify sync() updates both targets to current tradable reserves.
        _seedAsOwner(1_000_000_000, 1_000_000_000);

        uint256 b0Before = hook.baseTargetE18();
        uint256 q0Before = hook.quoteTargetE18();

        // Balanced 1% donation — vault-backed: bump junior reserves directly,
        // leaving targets stale until sync() captures them.
        vault.setReserve(address(token0), 1_000_000_000 + 10_000_000);
        vault.setReserve(address(token1), 1_000_000_000 + 10_000_000);

        // Pre-sync: targets unchanged from the reserve bump.
        assertEq(hook.baseTargetE18(), b0Before, "targets shifted without sync");

        // Owner predicts post-sync targets off-chain and submits with 1% drift tolerance.
        // 6-dec tokens → 1e18-norm. Pre-deposit was 1e9 raw → 1e21 norm. +1% donation → 1.01e21.
        uint256 expectedBase = 1_010_000_000_000_000_000_000;
        uint256 expectedQuote = 1_010_000_000_000_000_000_000;
        vm.prank(owner);
        hook.sync(expectedBase, expectedQuote, 100); // 1% drift tolerance
        assertGt(hook.baseTargetE18(), b0Before, "sync did not grow baseTarget");
        assertGt(hook.quoteTargetE18(), q0Before, "sync did not grow quoteTarget");

        // Post-sync quote at equilibrium — donation now backs LP value.
        uint256 postSyncQuote = hook.quote(10_000, true);
        assertGt(postSyncQuote, 0);
    }

    function test_sync_revertsBeforeFirstSeed() public {
        // Un-seeded vault → _vaultReserve(TOKEN0/TOKEN1) == 0 → sync reverts ZeroAmount.
        vm.expectRevert();
        vm.prank(owner);
        hook.sync(0, 0, 10_000);
    }

    function test_sync_revertsForNonOwner() public {
        _seedAsOwner(1_000_000_000, 1_000_000_000);
        vm.expectRevert();
        vm.prank(alice);
        hook.sync(1e21, 1e21, 100);
    }

    function test_sync_revertsOnDriftExceedingTolerance() public {
        // Sandwich-resistance regression: an attacker who moves reserves
        // between owner submission and execution forces actual reserves
        // outside the owner's expected envelope, reverting sync.
        _seedAsOwner(1_000_000_000, 1_000_000_000);

        // "Sandwich" pushes the vault reserve to 1.05× expected (vault-backed:
        // sync reads _vaultReserve, so the drift is a reserve bump not a transfer).
        vault.setReserve(address(token0), 1_050_000_000);

        // Owner expected 1e21 baseTarget; actual is 1.05e21 (5% drift).
        // Tolerance 1% (100 bps) → must revert.
        vm.expectRevert();
        vm.prank(owner);
        hook.sync(1e21, 1e21, 100);
    }

    // Was `test_deposit_firstDepositRevertsOnOneSided` (codex-2.7 r1) and
    // `test_deposit_firstDepositRevertsForNonOwner` (codex-2.7 r13). Vault-backed
    // refactor: `deposit()` is dead for ALL inputs/callers — it reverts UseVault
    // before any one-sided / owner-gating check can run. Both regressions are
    // subsumed: there is no longer any deposit path that could brick the curve or
    // poison equilibrium. Asserting the unconditional revert here.
    function test_deposit_revertsUseVaultForAnyInput() public {
        vm.startPrank(owner);
        vm.expectRevert(FxSwapHook.UseVault.selector);
        hook.deposit(1_000_000, 0);
        vm.expectRevert(FxSwapHook.UseVault.selector);
        hook.deposit(0, 1_000_000);
        vm.stopPrank();
        // Non-owner also hits UseVault (no owner-gate reached).
        vm.expectRevert(FxSwapHook.UseVault.selector);
        vm.prank(alice);
        hook.deposit(1_000_000, 1_000_000);
    }

    // Was `test_redeem_shrinksTargetsProRata`. Vault-backed refactor: `redeem()`
    // can no longer mutate the PMM targets — it reverts UseVault. Pro-rata target
    // shrink is gone; the dead-function behavior is covered by
    // `test_redeem_revertsUseVault`. Deleted (no replacement needed).

    function test_quote_K0_isStraightMidMinusSpread() public {
        _seedAsOwner(1_000_000_000, 1_000_000_000);
        vm.prank(owner);
        hook.setKBps(0);

        // K=0, mid=1, 30bps spread → 1000 in returns exactly 997.
        uint256 amountOut = hook.quote(1_000, true);
        assertEq(amountOut, 997);
    }

    function test_quote_K_positive_addsCurveSlippageOnTopOfSpread() public {
        _seedAsOwner(1_000_000_000, 1_000_000_000);
        vm.prank(owner);
        hook.setKBps(500); // 5% K — quite curved

        uint256 tinyOut = hook.quote(1_000, true);
        uint256 bigOut  = hook.quote(500_000_000, true);

        uint256 tinyRate = (tinyOut * 1e18) / 1_000;
        uint256 bigRate  = (bigOut * 1e18) / 500_000_000;
        // Big trade should be worse than tiny one by more than just spread.
        assertLt(bigRate, tinyRate);
        // And the big-trade rate worse than (mid * (1 - spread))
        assertLt(bigRate, 0.997e18);
    }

    function test_quote_revertsBeforeFirstSync() public {
        // No sync yet → targets are 0 → _quote short-circuits (baseTarget_/quoteTarget_
        // == 0) and returns 0 cleanly. Vault reserves are also 0 here. Assert no revert.
        uint256 amountOut = hook.quote(1_000, true);
        assertEq(amountOut, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PROTOCOL FEE SLEEVE (Phase 2.7 #3)
    //////////////////////////////////////////////////////////////*/

    function test_protocolFee_defaultsToZeroAndTreasuryIsOwner() public view {
        assertEq(hook.protocolFeeBps(), 0);
        assertEq(hook.treasury(), owner);
        assertEq(hook.protocolFee0(), 0);
        assertEq(hook.protocolFee1(), 0);
    }

    function test_setProtocolFeeBps_revertsAboveMax() public {
        uint16 maxBps = hook.MAX_PROTOCOL_FEE_BPS();
        vm.expectRevert();
        vm.prank(owner);
        hook.setProtocolFeeBps(maxBps + 1);
    }

    function test_setProtocolFeeBps_updates() public {
        vm.prank(owner);
        hook.setProtocolFeeBps(2_000);
        assertEq(hook.protocolFeeBps(), 2_000);
    }

    function test_setTreasury_updatesAndRevertsOnZero() public {
        address newTreasury = address(0xC0FFEE);
        vm.prank(owner);
        hook.setTreasury(newTreasury);
        assertEq(hook.treasury(), newTreasury);

        vm.expectRevert();
        vm.prank(owner);
        hook.setTreasury(address(0));
    }

    function test_claimProtocolFees_revertsForNonTreasury() public {
        vm.expectRevert();
        vm.prank(alice);
        hook.claimProtocolFees(address(token0), alice, 1);
    }

    function test_claimProtocolFees_revertsOnExcessiveAmount() public {
        vm.expectRevert();
        vm.prank(owner); // owner is the default treasury
        hook.claimProtocolFees(address(token0), owner, 1);
    }

    function test_claimProtocolFees_revertsOnInvalidToken() public {
        vm.expectRevert();
        vm.prank(owner);
        hook.claimProtocolFees(address(0xBAD), owner, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          POOL KEY ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_beforeInitialize_revertsOnWrongTokens() public {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0xDEAD)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        hook.beforeInitialize(address(0), badKey, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            CTOR GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert();
        new FxSwapHook(address(0), address(oracle), registry, owner, address(token0), address(token1), address(0x4444), address(0x5555));
        vm.expectRevert();
        new FxSwapHook(poolManager, address(oracle), registry, owner, address(token0), address(token1), address(0), address(0x5555));
    }

    /// @dev Vault-backed: returns the hook AND its dedicated MockFxVault. `a` is
    ///      the USD-side token (USDC) in both callers, so the vault's `asset` is set
    ///      to `a` — `_vaultReserve(a)` then reads `juniorUsdc()`, the other token
    ///      reads `juniorTokenBalance()`, matching production semantics.
    function _newHotOnlyHook(MockERC20 a, MockERC20 b, int64 priceA, int64 priceB)
        internal
        returns (FxSwapHook h, MockFxVault v)
    {
        MockPyth p = new MockPyth();
        FxOracle o = new FxOracle(address(p), owner, 60, 50, 30);

        bytes32 feedA = keccak256(abi.encodePacked(address(a)));
        bytes32 feedB = keccak256(abi.encodePacked(address(b)));
        vm.startPrank(owner);
        o.setFeed(address(a), feedA);
        o.setFeed(address(b), feedB);
        vm.stopPrank();

        p.setPrice(feedA, priceA, 100, -8, block.timestamp);
        p.setPrice(feedB, priceB, 100, -8, block.timestamp);

        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        v = new MockFxVault(address(a)); // asset = USD-side token
        h = new FxSwapHook(poolManager, address(o), registry, owner, t0, t1, address(0x4444), address(v));
        vm.prank(owner);
        h.setHotReservePct(10_000);
    }

    /// @dev Vault-backed seed for the JPYC/KRW1 hooks: set both junior reserves on
    ///      `v`, then sync the hook's PMM targets to them (drift 0 → always passes).
    function _depositSorted(
        FxSwapHook h,
        MockFxVault v,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB
    ) internal {
        _seedVault(h, v, tokenA, amountA, tokenB, amountB);
    }
}
