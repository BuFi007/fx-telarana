// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, MarketParams as MorphoMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {FxPrivacyPool} from "../src/hub/FxPrivacyPool.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";
import {IVerifier} from "privacy-pools/interfaces/IVerifier.sol";
import {Constants as PpConstants} from "privacy-pools/contracts/lib/Constants.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice Always-true Groth16 stub for fork tests — proof verification is
///         the SDK's responsibility (slice 4); fork tests exercise the
///         rehypothecation pattern against real Morpho Blue.
contract ForkMockVerifier is IVerifier {
    function verifyProof(uint256[2] memory, uint256[2][2] memory, uint256[2] memory, uint256[8] memory)
        external pure returns (bool) { return true; }
    function verifyProof(uint256[2] memory, uint256[2][2] memory, uint256[2] memory, uint256[4] memory)
        external pure returns (bool) { return true; }
}

/// @notice Fork-test the FxMarketRegistry + FxReceipt + FxLiquidator stack against
///         the real Morpho Blue deployment on Ethereum mainnet. Skipped unless
///         `ETH_RPC_URL` env var is set.
contract MainnetForkTest is Test {
    using MarketParamsLib for MorphoMarketParams;

    // Ethereum mainnet (chainId 1)
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant EURC = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;

    // 86% LLTV is in widespread mainnet use → already enabled by Morpho governance
    uint256 constant LLTV = 0.86e18;

    bytes32 constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;

    IMorpho internal morpho;
    FxOracle internal fxOracle;
    MockPyth internal pyth;
    FxMarketRegistry internal registry;
    MorphoOracleAdapter internal adapterM1; // loan=EURC, collat=USDC
    MorphoOracleAdapter internal adapterM2; // loan=USDC, collat=EURC
    FxReceipt internal fxUSDC;
    FxReceipt internal fxEURC;
    FxLiquidator internal liquidator;
    FxSwapHook internal hook;
    address internal hookPoolManager = address(0x9999); // mock — fork tests don't exercise the v4 swap path

    address internal owner = address(0xA11CE);
    address internal lender = address(0xBABE);
    address internal borrower = address(0xCAFE);

    bool internal forkActive;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            return;
        }
        vm.createSelectFork(rpc);
        forkActive = true;

        morpho = IMorpho(MORPHO);

        // Deploy FxOracle with mock Pyth (we control prices in tests; real Pyth feed
        // ids are pre-wired for the deployment scripts).
        pyth = new MockPyth();
        fxOracle = new FxOracle(address(pyth), owner, 600, 100, 100);
        vm.startPrank(owner);
        fxOracle.setFeed(USDC, PYTH_USDC_USD);
        fxOracle.setFeed(EURC, PYTH_EURC_USD);
        vm.stopPrank();

        pyth.setPrice(PYTH_USDC_USD, 1_00_000_000, 100, -8, block.timestamp);
        pyth.setPrice(PYTH_EURC_USD, 1_08_000_000, 100, -8, block.timestamp);

        adapterM1 = new MorphoOracleAdapter(address(fxOracle), EURC, USDC);
        adapterM2 = new MorphoOracleAdapter(address(fxOracle), USDC, EURC);

        registry = new FxMarketRegistry(MORPHO, owner);

        // Ensure LLTV is enabled on Morpho. 0.86e18 is typically enabled mainnet;
        // if not, prank Morpho owner to enable it.
        if (!morpho.isLltvEnabled(LLTV)) {
            address morphoOwner = morpho.owner();
            vm.prank(morphoOwner);
            morpho.enableLltv(LLTV);
        }
        if (!morpho.isIrmEnabled(ADAPTIVE_IRM)) {
            address morphoOwner = morpho.owner();
            vm.prank(morphoOwner);
            morpho.enableIrm(ADAPTIVE_IRM);
        }

        // M1: loan=EURC, collateral=USDC
        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: EURC, collateralToken: USDC, oracle: address(adapterM1), irm: ADAPTIVE_IRM, lltv: LLTV
        });
        vm.prank(owner);
        registry.createAndRegisterMarket(m1);

        // M2: loan=USDC, collateral=EURC
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: USDC, collateralToken: EURC, oracle: address(adapterM2), irm: ADAPTIVE_IRM, lltv: LLTV
        });
        vm.prank(owner);
        registry.createAndRegisterMarket(m2);

        fxUSDC = new FxReceipt(
            IERC20(USDC),
            "fxUSDC supply receipt",
            "fxUSDC",
            MORPHO,
            MorphoMarketParams({
                loanToken: USDC, collateralToken: EURC, oracle: address(adapterM2), irm: ADAPTIVE_IRM, lltv: LLTV
            })
        );
        fxEURC = new FxReceipt(
            IERC20(EURC),
            "fxEURC supply receipt",
            "fxEURC",
            MORPHO,
            MorphoMarketParams({
                loanToken: EURC, collateralToken: USDC, oracle: address(adapterM1), irm: ADAPTIVE_IRM, lltv: LLTV
            })
        );

        liquidator = new FxLiquidator(MORPHO, address(registry), address(fxOracle), owner);

        // FxSwapHook — locked to (USDC, EURC) and the real Morpho instance.
        // PoolManager is a mock since these fork tests exercise only the LP +
        // rehypothecation paths, not the v4 swap callbacks.
        (address t0, address t1) = USDC < EURC ? (USDC, EURC) : (EURC, USDC);
        hook = new FxSwapHook(hookPoolManager, address(fxOracle), address(registry), owner, t0, t1, MORPHO);
        // Default 20% hot, 80% Morpho

        // Fund test users via Foundry's `deal` cheatcode
        deal(USDC, lender, 1_000_000e6);
        deal(EURC, lender, 1_000_000e6);
        deal(USDC, borrower, 1_000_000e6);
        deal(EURC, borrower, 1_000_000e6);
        deal(USDC, owner, 1_000_000e6);
        deal(EURC, owner, 1_000_000e6);
    }

    /// @notice Owner bootstraps the hook so subsequent lender deposits work
    ///         under the codex-r12 owner-gated first-deposit rule. Uses tiny
    ///         amounts (100 USDC / 100 EURC) so the seed-induced drift on
    ///         downstream hot/total assertions stays well within tolerance.
    function _bootstrapHookAsOwner() internal {
        (address t0, address t1) = USDC < EURC ? (USDC, EURC) : (EURC, USDC);
        vm.startPrank(owner);
        IERC20(t0).approve(address(hook), type(uint256).max);
        IERC20(t1).approve(address(hook), type(uint256).max);
        hook.deposit(100e6, 100e6);
        vm.stopPrank();
    }

    modifier whenFork() {
        if (!forkActive) {
            console_log("ETH_RPC_URL not set; skipping fork test");
            return;
        }
        _;
    }

    function console_log(string memory s) internal pure {
        s; // forge-std console import would inflate compile; this is a no-op gate marker
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fork_registry_routesSupply() public whenFork {
        // Lender supplies 100,000 USDC into M2
        vm.startPrank(lender);
        IERC20(USDC).approve(address(registry), type(uint256).max);
        uint256 shares = registry.supply(USDC, EURC, 100_000e6, lender);
        vm.stopPrank();

        assertGt(shares, 0, "supply minted no shares");
    }

    function test_fork_borrow_againstCollateral() public whenFork {
        // Lender supplies 100k USDC into M2 (loan side)
        vm.startPrank(lender);
        IERC20(USDC).approve(address(registry), type(uint256).max);
        registry.supply(USDC, EURC, 100_000e6, lender);
        vm.stopPrank();

        // Borrower deposits 50k EURC as collateral in M2 and borrows 30k USDC
        vm.startPrank(borrower);
        IERC20(EURC).approve(address(registry), type(uint256).max);
        registry.supplyCollateral(USDC, EURC, 50_000e6, borrower);

        // Authorize registry so it can borrow on borrower's behalf
        morpho.setAuthorization(address(registry), true);

        registry.borrow(USDC, EURC, 30_000e6, borrower, borrower);
        vm.stopPrank();

        // Borrower now has +30k USDC + remaining EURC
        assertGe(IERC20(USDC).balanceOf(borrower), 1_030_000e6 - 1);
    }

    function test_fork_borrowDelegated_againstCollateral() public whenFork {
        address delegate = address(0xDE1E64A7E);

        vm.startPrank(lender);
        IERC20(USDC).approve(address(registry), type(uint256).max);
        registry.supply(USDC, EURC, 100_000e6, lender);
        vm.stopPrank();

        vm.startPrank(borrower);
        IERC20(EURC).approve(address(registry), type(uint256).max);
        registry.supplyCollateral(USDC, EURC, 50_000e6, borrower);
        morpho.setAuthorization(address(registry), true);
        registry.setBorrowDelegate(delegate, true);
        vm.stopPrank();

        vm.prank(delegate);
        uint256 borrowedShares = registry.borrowDelegated(USDC, EURC, 30_000e6, borrower, borrower);

        assertGt(borrowedShares, 0, "delegated borrow minted no debt shares");
        assertGe(IERC20(USDC).balanceOf(borrower), 1_030_000e6 - 1);
    }

    function test_fork_fxReceipt_depositAndWithdraw() public whenFork {
        vm.startPrank(lender);
        IERC20(USDC).approve(address(fxUSDC), type(uint256).max);

        uint256 shares = fxUSDC.deposit(100_000e6, lender);
        assertGt(shares, 0);

        // Roll time so interest may accrue (here utilization is 0; assets ~ unchanged)
        skip(7 days);

        uint256 assetsOut = fxUSDC.redeem(shares, lender, lender);
        vm.stopPrank();

        // Without borrowing, no interest accrues — receipt should return ~ deposit
        assertApproxEqAbs(assetsOut, 100_000e6, 10);
    }

    /*//////////////////////////////////////////////////////////////
                        FxSwapHook PHASE 2.6 REHYPOTHECATION
    //////////////////////////////////////////////////////////////*/

    function test_fork_swapHook_depositRehypothecates() public whenFork {
        _bootstrapHookAsOwner();
        // hotReservePct default = 2000 (20% hot, 80% Morpho)
        address t0 = USDC < EURC ? USDC : EURC;
        address t1 = USDC < EURC ? EURC : USDC;

        vm.startPrank(lender);
        IERC20(t0).approve(address(hook), type(uint256).max);
        IERC20(t1).approve(address(hook), type(uint256).max);
        uint256 shares = hook.deposit(100_000e6, 100_000e6);
        vm.stopPrank();

        assertGt(shares, 0, "no LP shares minted");

        // ~20% hot after the lender deposit (plus the tiny owner-bootstrap seed).
        // Tolerance widened from 1 wei to 0.5% to absorb the 1_000e6 seed.
        uint256 hot0 = IERC20(t0).balanceOf(address(hook));
        uint256 hot1 = IERC20(t1).balanceOf(address(hook));
        assertApproxEqRel(hot0, 20_000e6, 0.005e18, "hot t0 should be ~20% of deposit");
        assertApproxEqRel(hot1, 20_000e6, 0.005e18, "hot t1 should be ~20% of deposit");

        // 80% supplied into Morpho
        assertGt(hook.morphoShares(t0), 0, "no morpho shares for t0");
        assertGt(hook.morphoShares(t1), 0, "no morpho shares for t1");
    }

    function test_fork_swapHook_redeemPullsFromMorpho() public whenFork {
        _bootstrapHookAsOwner();
        address t0 = USDC < EURC ? USDC : EURC;
        address t1 = USDC < EURC ? EURC : USDC;

        vm.startPrank(lender);
        IERC20(t0).approve(address(hook), type(uint256).max);
        IERC20(t1).approve(address(hook), type(uint256).max);
        uint256 shares = hook.deposit(100_000e6, 100_000e6);

        uint256 t0BalBefore = IERC20(t0).balanceOf(lender);
        uint256 t1BalBefore = IERC20(t1).balanceOf(lender);

        (uint256 out0, uint256 out1) = hook.redeem(shares);
        vm.stopPrank();

        // Lender gets back ~99% of deposit (a tiny dust to address(0) for bootstrap)
        assertApproxEqRel(out0, 100_000e6, 0.001e18);
        assertApproxEqRel(out1, 100_000e6, 0.001e18);
        assertEq(IERC20(t0).balanceOf(lender), t0BalBefore + out0);
        assertEq(IERC20(t1).balanceOf(lender), t1BalBefore + out1);
    }

    function test_fork_swapHook_rebalanceDoesNotWithdrawWhenHotBelowTarget() public whenFork {
        _bootstrapHookAsOwner();
        address t0 = USDC < EURC ? USDC : EURC;
        address t1 = USDC < EURC ? EURC : USDC;

        // Start: deposit at default 20% hot
        vm.startPrank(lender);
        IERC20(t0).approve(address(hook), type(uint256).max);
        IERC20(t1).approve(address(hook), type(uint256).max);
        hook.deposit(100_000e6, 100_000e6);
        vm.stopPrank();

        uint256 morpho0Before = hook.morphoShares(t0);
        assertGt(morpho0Before, 0);

        // Increase target to 100% hot. rebalance() only PUSHES excess to Morpho
        // (it doesn't withdraw). So with hot=20% < target=100%, nothing happens.
        vm.startPrank(owner);
        hook.setHotReservePct(10_000);
        hook.rebalance();
        vm.stopPrank();

        assertEq(hook.morphoShares(t0), morpho0Before, "rebalance must not withdraw");
    }

    function test_fork_swapHook_secondDepositPushesExcessToMorpho() public whenFork {
        _bootstrapHookAsOwner();
        address t0 = USDC < EURC ? USDC : EURC;
        address t1 = USDC < EURC ? EURC : USDC;

        vm.startPrank(lender);
        IERC20(t0).approve(address(hook), type(uint256).max);
        IERC20(t1).approve(address(hook), type(uint256).max);
        hook.deposit(100_000e6, 100_000e6); // first deposit at 20% hot
        uint256 morpho0AfterFirst = hook.morphoShares(t0);

        hook.deposit(50_000e6, 50_000e6); // second deposit — should rebalance push
        uint256 morpho0AfterSecond = hook.morphoShares(t0);
        vm.stopPrank();

        assertGt(morpho0AfterSecond, morpho0AfterFirst, "second deposit must push excess hot into morpho");
    }

    function test_fork_marketIds_deterministic() public whenFork {
        bytes32 m1id = registry.marketIdOf(EURC, USDC);
        bytes32 m2id = registry.marketIdOf(USDC, EURC);
        assertTrue(m1id != bytes32(0));
        assertTrue(m2id != bytes32(0));
        assertTrue(m1id != m2id);

        IFxMarketRegistry.MarketParams memory p = registry.paramsOf(EURC, USDC);
        assertEq(p.loanToken, EURC);
        assertEq(p.collateralToken, USDC);
    }

    function test_fork_setPoolLive_isolatesPair() public whenFork {
        bytes32 m1id = registry.marketIdOf(EURC, USDC);

        vm.prank(owner);
        registry.setPoolLive(EURC, USDC, false);
        assertFalse(registry.isPoolLive(EURC, USDC));
        assertTrue(registry.isPoolLive(USDC, EURC));

        vm.startPrank(lender);
        IERC20(EURC).approve(address(registry), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IFxMarketRegistry.PoolNotLive.selector, m1id));
        registry.supply(EURC, USDC, 100_000e6, lender);

        IERC20(USDC).approve(address(registry), type(uint256).max);
        uint256 shares = registry.supply(USDC, EURC, 100_000e6, lender);
        vm.stopPrank();

        assertGt(shares, 0, "unpaused paired market should still accept supply");
    }

    function test_fork_setPoolLive_revertsWithoutOpsRole() public whenFork {
        address random = address(0xB0B);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, random, registry.OPERATIONS_ROLE()
            )
        );
        vm.prank(random);
        registry.setPoolLive(EURC, USDC, false);
    }

    /*//////////////////////////////////////////////////////////////
                PR-3 integrator-surface shims (listPools, etc.)
    //////////////////////////////////////////////////////////////*/

    function test_fork_listPools_enumeratesBoth() public whenFork {
        IFxMarketRegistry.MarketParams[] memory pools = registry.listPools();
        assertEq(pools.length, 2, "two markets registered (M1 + M2)");
        // Registration order in setUp: M1 (loan=EURC), then M2 (loan=USDC).
        assertEq(pools[0].loanToken, EURC);
        assertEq(pools[1].loanToken, USDC);
    }

    /*//////////////////////////////////////////////////////////////
                R1 INFLATION-ATTACK DEFENSE (audit v1.2.2)
    //////////////////////////////////////////////////////////////*/

    /// @notice Sanity: a direct USDC transfer to the wrapper must NOT shift share
    /// price. `FxReceipt.totalAssets()` reads `MORPHO.expectedSupplyAssets`, not
    /// `asset.balanceOf(this)` — adversarial pass empirically disproved the
    /// classical direct-donation variant. Pin the no-op so a future regression
    /// surfaces loud. (`docs/SPEC_PHASE_3_MULTI_STABLECOIN.md` §9.1.)
    function test_fork_r1_directDonationIsInert() public whenFork {
        address attacker = address(0x4774CE);
        deal(USDC, attacker, 10_000_000e6);

        vm.startPrank(attacker);
        IERC20(USDC).approve(address(fxUSDC), type(uint256).max);
        uint256 attackerShares = fxUSDC.deposit(1, attacker);
        vm.stopPrank();

        uint256 ppdBefore = fxUSDC.previewDeposit(1e6);

        // Direct donation — should be a no-op for share pricing.
        vm.prank(attacker);
        IERC20(USDC).transfer(address(fxUSDC), 1_000_000e6);

        uint256 ppdAfter = fxUSDC.previewDeposit(1e6);

        assertEq(ppdAfter, ppdBefore, "direct USDC transfer must not alter share price");
        assertEq(attackerShares, 1e6, "1-wei deposit with offset=6 mints 10^6 shares");
    }

    /// @notice The real attack vector: Morpho-side donation. Anyone can call
    /// `MORPHO.supply(params, x, 0, wrapper, "")` to mint shares to the wrapper's
    /// Morpho position, which IS counted by `expectedSupplyAssets`. With
    /// `_decimalsOffset()=6`, the attacker's required donation to round the
    /// victim to zero is multiplied by 1e6, making the steal negative-EV.
    /// Asserts the victim recovers ≥99% of deposit after redeem.
    /*//////////////////////////////////////////////////////////////
                    FX PRIVACY POOL (slice 2 rehyp)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit splits into hot reserve + Morpho supply at the
    ///         configured ratio against the real Morpho Blue protocol.
    function test_fork_privacyPool_depositRehypothecates() public whenFork {
        ForkMockVerifier wv = new ForkMockVerifier();
        ForkMockVerifier rv = new ForkMockVerifier();
        // Entrypoint = test (`address(this)`) so we can call deposit directly.
        FxPrivacyPool pool = new FxPrivacyPool(
            address(this), address(wv), address(rv), USDC, owner,
            MORPHO, address(registry), EURC
        );

        // hotReservePct default = 2000 (20%). Lender supplies 10k USDC.
        uint256 amount = 10_000e6;
        deal(USDC, address(this), amount);
        IERC20(USDC).approve(address(pool), amount);
        uint256 commitment = pool.deposit(lender, amount, _fakePrecommitment(0xA));

        assertGt(commitment, 0, "no commitment minted");
        assertApproxEqRel(pool.hotBalance(),         2_000e6, 0.005e18, "~20% hot");
        assertApproxEqRel(pool.morphoSupplyAssets(), 8_000e6, 0.005e18, "~80% in Morpho");
        assertApproxEqRel(pool.totalAssets(),        amount,  0.001e18, "total reconciles");
        assertGt(pool.morphoShares(), 0, "no Morpho shares");
    }

    /// @notice JIT-withdraw on `_push` pulls from Morpho when hot < amount.
    ///         Simulates the post-withdrawal flow: pool calls `_push` to
    ///         `recipient` via the Entrypoint, requiring more than hot.
    ///         We exercise it via a second deposit followed by manual wind-out.
    function test_fork_privacyPool_supplyAndWithdrawRoundtrip() public whenFork {
        ForkMockVerifier wv = new ForkMockVerifier();
        ForkMockVerifier rv = new ForkMockVerifier();
        FxPrivacyPool pool = new FxPrivacyPool(
            address(this), address(wv), address(rv), USDC, owner,
            MORPHO, address(registry), EURC
        );

        // Deposit 10k USDC → 2k hot, 8k Morpho
        uint256 amount = 10_000e6;
        deal(USDC, address(this), amount);
        IERC20(USDC).approve(address(pool), amount);
        pool.deposit(lender, amount, _fakePrecommitment(0xB));

        uint256 hotBefore     = pool.hotBalance();
        uint256 morphoBefore  = pool.morphoSupplyAssets();
        uint256 totalBefore   = pool.totalAssets();
        assertApproxEqRel(totalBefore, amount, 0.001e18, "total assets before");

        // Owner re-tightens to 100% hot → forces a withdraw from Morpho.
        // (Same code path slice 4's _push will hit on a real withdraw.)
        vm.prank(owner);
        pool.setHotReservePct(10_000);

        assertApproxEqRel(pool.hotBalance(), amount, 0.001e18, "after rebalance: all hot");
        assertLt(pool.morphoSupplyAssets(),  morphoBefore, "morpho supply decreased");
        assertApproxEqRel(pool.totalAssets(), totalBefore, 0.001e18, "no loss on round-trip");
        // shares should be ~0 after full unwind (allow rounding)
        assertLe(pool.morphoShares(), 1e3, "shares fully burned (modulo dust)");
        hotBefore; // silence unused
    }

    function _fakePrecommitment(uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("fork-precommitment", salt))) %
               PpConstants.SNARK_SCALAR_FIELD;
    }

    function test_fork_r1_morphoSideDonationDefended() public whenFork {
        address attacker = address(0x4774CE);
        address victim = address(0x71C71E);
        deal(USDC, attacker, 10_000_000e6);
        deal(USDC, victim, 1_000_000e6);

        // ActorA = attacker: deposit 1 wei.
        vm.startPrank(attacker);
        IERC20(USDC).approve(address(fxUSDC), type(uint256).max);
        fxUSDC.deposit(1, attacker);
        vm.stopPrank();

        // Morpho-side donation: 1M USDC supplied on behalf of the wrapper.
        // This DOES inflate the wrapper's expectedSupplyAssets — unlike a
        // direct transfer, which would not.
        MorphoMarketParams memory m2 = MorphoMarketParams({
            loanToken: USDC, collateralToken: EURC, oracle: address(adapterM2), irm: ADAPTIVE_IRM, lltv: LLTV
        });
        vm.startPrank(attacker);
        IERC20(USDC).approve(MORPHO, type(uint256).max);
        morpho.supply(m2, 1_000_000e6, 0, address(fxUSDC), "");
        vm.stopPrank();

        uint256 victimDeposit = 100e6; // 100 USDC

        vm.startPrank(victim);
        IERC20(USDC).approve(address(fxUSDC), type(uint256).max);
        uint256 victimShares = fxUSDC.deposit(victimDeposit, victim);
        uint256 victimRedeemed = fxUSDC.redeem(victimShares, victim, victim);
        vm.stopPrank();

        // With `_decimalsOffset()=6` the victim recovers approximately the full
        // deposit despite the donation. Tolerance 1% covers rounding floors.
        assertGe(
            victimRedeemed, victimDeposit * 99 / 100, "R1 defense failed: victim lost > 1% to Morpho-side donation"
        );

        // Attacker share value never exceeds what they put in (1M donation + 1 wei seed).
        uint256 attackerShareValue = fxUSDC.previewRedeem(fxUSDC.balanceOf(attacker));
        assertLt(attackerShareValue, 1_000_001e6, "attacker share value must not exceed their own donation+seed");
    }
}
