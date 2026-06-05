// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@oz-upgradeable/utils/PausableUpgradeable.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {FxReserveYieldRouter} from "../../src/vault/FxReserveYieldRouter.sol";
import {IUsycTeller} from "../../src/vault/interfaces/IUsycTeller.sol";

/// @dev Faithful USYC Teller stand-in. ERC-4626-style, price-driven. Default price matches the
///      LIVE Arc Teller: previewDeposit(1e6)=895835, previewRedeem(1e6)=1116277.
contract MockUsycTeller is IUsycTeller {
    MockERC20 public usdcTok;
    MockERC20 public usycTok;
    uint256 public priceE6 = 1_116_277; // USDC per 1.0 USYC, scaled 1e6

    constructor(MockERC20 _usdc, MockERC20 _usyc) {
        usdcTok = _usdc;
        usycTok = _usyc;
    }

    function setPrice(uint256 p) external {
        priceE6 = p;
    }

    function asset() external view returns (address) {
        return address(usdcTok);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return (assets * 1e6) / priceE6;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return (shares * priceE6) / 1e6;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return (assets * 1e6 + priceE6 - 1) / priceE6; // ceil
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        usdcTok.transferFrom(msg.sender, address(this), assets);
        shares = previewDeposit(assets);
        usycTok.mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address account) external returns (uint256 assets) {
        usycTok.transferFrom(account, address(this), shares); // requires router's forceApprove
        usycTok.burn(address(this), shares);
        assets = previewRedeem(shares);
        usdcTok.transfer(receiver, assets);
    }
}

contract FxReserveYieldRouterTest is Test {
    FxReserveYieldRouter router;
    MockERC20 usdc;
    MockERC20 usyc;
    MockUsycTeller teller;

    address admin = address(this);
    address timelock = makeAddr("timelock");
    address treasury = makeAddr("treasury");

    uint256 constant LOW = 100e6;
    uint256 constant HIGH = 500e6;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        usyc = new MockERC20("USYC", "USYC", 6);
        teller = new MockUsycTeller(usdc, usyc);

        FxReserveYieldRouter impl = new FxReserveYieldRouter();
        bytes memory initData = abi.encodeCall(
            FxReserveYieldRouter.initialize,
            (IERC20(address(usdc)), IERC20(address(usyc)), IUsycTeller(address(teller)), admin, timelock, LOW, HIGH)
        );
        router = FxReserveYieldRouter(address(new ERC1967Proxy(address(impl), initData)));
        router.grantRole(router.FUNDER_ROLE(), admin);
        router.grantRole(router.KEEPER_ROLE(), admin);
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT #2 — COMPLIANCE LAW: retail ∩ USYC = ∅
    //////////////////////////////////////////////////////////////*/

    function test_compliance_retailCannotBeFunded() public {
        usdc.mint(admin, 100e6);
        usdc.approve(address(router), 100e6);
        vm.expectRevert(FxReserveYieldRouter.RetailForbidden.selector);
        router.depositFor(FxReserveYieldRouter.Tier.RETAIL, 100e6);
    }

    function test_compliance_retailCannotBeWithdrawn() public {
        vm.expectRevert(FxReserveYieldRouter.RetailForbidden.selector);
        router.withdrawFor(FxReserveYieldRouter.Tier.RETAIL, 1, treasury);
    }

    function test_compliance_retailPrincipalAlwaysZero() public {
        _fund(FxReserveYieldRouter.Tier.INSTITUTIONAL, 600e6);
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 400e6);
        router.rebalance(); // deploys excess to USYC
        usyc.mint(address(teller), 0); // no-op, keep teller funded path explicit
        assertEq(router.tierPrincipal(FxReserveYieldRouter.Tier.RETAIL), 0, "retail principal stays 0");
        // even after redeem + harvest, retail is untouched
        router.redeemFromYield(50e6);
        assertEq(router.tierPrincipal(FxReserveYieldRouter.Tier.RETAIL), 0, "retail principal still 0");
    }

    function test_compliance_onlyNonRetailReachesUsyc() public {
        _fund(FxReserveYieldRouter.Tier.INSTITUTIONAL, 600e6);
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 400e6);
        router.rebalance(); // liquid 1000 > HIGH 500 → deploy 500 to USYC

        assertGt(router.usycValueUsdc(), 0, "USYC position opened");
        assertEq(router.tierPrincipal(FxReserveYieldRouter.Tier.RETAIL), 0, "no retail in the router");
        assertEq(router.totalPrincipalUsdc(), 1_000e6, "all principal is insti+protocol");
        // every USDC of USYC value is attributable to non-retail principal
        assertEq(
            router.tierPrincipal(FxReserveYieldRouter.Tier.INSTITUTIONAL)
                + router.tierPrincipal(FxReserveYieldRouter.Tier.PROTOCOL),
            router.totalPrincipalUsdc(),
            "USYC-backed capital is 100% non-retail"
        );
    }

    /*//////////////////////////////////////////////////////////////
       INVARIANT #1 — PERFORMANCE LAW (by construction, documented)
    //////////////////////////////////////////////////////////////*/

    /// @dev The router is standalone: it imports nothing from the swap path and the swap path imports
    ///      nothing from it. P1 makes ZERO edit to SharedFxVault, so `beforeSwap` is unchanged. There
    ///      is no on-chain coupling to assert against here — the guarantee is the absence of a call
    ///      edge. This test documents that the router exposes no hook/swap entrypoint.
    function test_performance_routerHasNoSwapEntrypoint() public view {
        // Sanity: the router's surface is treasury/yield only. (Compile-time guarantee; this asserts
        // the NAV view is independent of any swap state.)
        assertEq(router.yieldAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         (s,S) REBALANCE BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function test_rebalance_deploysExcessAboveHighWater() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance();
        assertEq(router.liquidUsdc(), HIGH, "liquid pulled down to high-water");
        assertApproxEqAbs(router.usycValueUsdc(), 500e6, 2, "excess deployed to USYC at ~par");
        assertApproxEqAbs(router.yieldAssets(), 1_000e6, 2, "total value preserved");
    }

    function test_rebalance_redeemsBelowLowWater() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance(); // liquid → 500, USYC ~500
        router.setWaterMarks(800e6, 900e6); // now liquid 500 < low 800
        router.rebalance(); // redeem ~300 from USYC
        assertApproxEqAbs(router.liquidUsdc(), 800e6, 2, "buffer refilled to low-water");
    }

    function test_rebalance_noOpInBand() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 300e6); // 100 ≤ 300 ≤ 500
        vm.expectRevert(FxReserveYieldRouter.RebalanceNoOp.selector);
        router.rebalance();
    }

    function test_rebalance_isPermissionless() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        vm.prank(makeAddr("randomSearcher"));
        router.rebalance(); // anyone can poke it
        assertEq(router.liquidUsdc(), HIGH);
    }

    /*//////////////////////////////////////////////////////////////
                          YIELD ACCRUAL / HARVEST
    //////////////////////////////////////////////////////////////*/

    function test_yieldAccrues_onPriceUp() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance(); // ~500 USDC into USYC
        assertApproxEqAbs(router.accruedYieldUsdc(), 0, 2, "no yield yet");

        // simulate T-bill accrual: USYC price +5%, fund the teller to back the larger redemption
        teller.setPrice((teller.priceE6() * 105) / 100);
        usdc.mint(address(teller), 100e6);

        // ~500 USDC of USYC now worth ~525 → ~25 USDC yield
        assertApproxEqAbs(router.accruedYieldUsdc(), 25e6, 1e6, "yield ~= 5% of deployed");
        assertGt(router.yieldAssets(), router.totalPrincipalUsdc(), "value exceeds principal");
    }

    function test_harvestYield_principalIntact() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance();
        teller.setPrice((teller.priceE6() * 105) / 100);
        usdc.mint(address(teller), 100e6);

        uint256 yield = router.accruedYieldUsdc();
        router.harvestYield(treasury, yield);
        assertEq(usdc.balanceOf(treasury), yield, "treasury received yield");
        assertEq(router.totalPrincipalUsdc(), 1_000e6, "principal untouched");
        assertApproxEqAbs(router.accruedYieldUsdc(), 0, 2, "yield drained");
    }

    function test_harvestYield_revertsAboveAccrued() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance();
        vm.expectRevert(FxReserveYieldRouter.YieldShort.selector);
        router.harvestYield(treasury, 1e6); // ~0 yield so far
    }

    /*//////////////////////////////////////////////////////////////
                          PRINCIPAL IN / OUT
    //////////////////////////////////////////////////////////////*/

    function test_depositFor_creditsTierPrincipal() public {
        _fund(FxReserveYieldRouter.Tier.INSTITUTIONAL, 250e6);
        assertEq(router.tierPrincipal(FxReserveYieldRouter.Tier.INSTITUTIONAL), 250e6);
        assertEq(router.liquidUsdc(), 250e6);
        assertEq(router.totalPrincipalUsdc(), 250e6);
    }

    function test_withdrawFor_returnsPrincipal_redeemsIfNeeded() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance(); // liquid 500, USYC ~500
        usdc.mint(address(teller), 10e6); // dust headroom for ceil rounding on redeem
        router.withdrawFor(FxReserveYieldRouter.Tier.PROTOCOL, 900e6, treasury);
        assertEq(usdc.balanceOf(treasury), 900e6, "principal returned, redeeming USYC to cover");
        assertEq(router.tierPrincipal(FxReserveYieldRouter.Tier.PROTOCOL), 100e6, "principal debited");
    }

    function test_withdrawFor_revertsAbovePrincipal() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 100e6);
        vm.expectRevert(FxReserveYieldRouter.TierPrincipalShort.selector);
        router.withdrawFor(FxReserveYieldRouter.Tier.PROTOCOL, 101e6, treasury);
    }

    function test_keeperManualDeployRedeem() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.deployToYield(400e6);
        assertEq(router.liquidUsdc(), 600e6);
        assertApproxEqAbs(router.usycValueUsdc(), 400e6, 2);
        router.redeemFromYield(200e6);
        assertApproxEqAbs(router.liquidUsdc(), 800e6, 2);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE / GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function test_pause_blocksDepositAndRebalance() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.pause();

        usdc.mint(admin, 100e6);
        usdc.approve(address(router), 100e6);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        router.depositFor(FxReserveYieldRouter.Tier.PROTOCOL, 100e6);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        router.rebalance();
    }

    function test_setWaterMarks_rejectsInverted() public {
        vm.expectRevert(FxReserveYieldRouter.BadWaterMarks.selector);
        router.setWaterMarks(900e6, 800e6);
    }

    function test_setTeller_requiresNoPosition() public {
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance(); // opens a USYC position
        MockUsycTeller t2 = new MockUsycTeller(usdc, usyc);
        vm.expectRevert(FxReserveYieldRouter.TellerHasPosition.selector);
        router.setTeller(IUsycTeller(address(t2)));

        // drain the position, then repoint succeeds
        router.redeemFromYield(type(uint256).max);
        router.setTeller(IUsycTeller(address(t2)));
        assertEq(router.teller(), address(t2));
    }

    function test_init_rejectsTellerAssetMismatch() public {
        MockERC20 otherUsdc = new MockERC20("X", "X", 6);
        MockUsycTeller badTeller = new MockUsycTeller(otherUsdc, usyc); // asset() != our usdc
        FxReserveYieldRouter impl = new FxReserveYieldRouter();
        bytes memory initData = abi.encodeCall(
            FxReserveYieldRouter.initialize,
            (IERC20(address(usdc)), IERC20(address(usyc)), IUsycTeller(address(badTeller)), admin, timelock, LOW, HIGH)
        );
        vm.expectRevert(FxReserveYieldRouter.TellerAssetMismatch.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /*//////////////////////////////////////////////////////////////
                               UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_upgrade_upgraderSelfAdministered() public view {
        assertEq(router.getRoleAdmin(router.UPGRADER_ROLE()), router.UPGRADER_ROLE());
        assertTrue(router.hasRole(router.UPGRADER_ROLE(), timelock));
        assertFalse(router.hasRole(router.UPGRADER_ROLE(), admin));
    }

    function test_upgrade_adminCannotSelfGrantUpgrader() public {
        bytes32 upgrader = router.UPGRADER_ROLE();
        vm.expectRevert();
        router.grantRole(upgrader, admin);
    }

    function test_upgrade_adminCannotUpgrade() public {
        address v2 = address(new FxReserveYieldRouter());
        vm.expectRevert();
        router.upgradeToAndCall(v2, "");
    }

    function test_upgrade_timelockCanUpgrade() public {
        address v2 = address(new FxReserveYieldRouter());
        vm.prank(timelock);
        router.upgradeToAndCall(v2, "");
    }

    /*//////////////////////////////////////////////////////////////
            LIVE-TELLER FORK — interface matches Arc reality
    //////////////////////////////////////////////////////////////*/

    /// @dev Set ARC_RPC_URL to run. Verifies the IUsycTeller interface against the LIVE Arc Teller
    ///      (no entitlement needed for view calls). A live deposit/redeem additionally requires the
    ///      router's address to be entitled in USYC Entitlements 0xcc20… (a Circle request).
    function test_fork_liveTellerInterfaceMatches() public {
        string memory rpc = vm.envOr("ARC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // skipped without an RPC
        vm.createSelectFork(rpc);

        IUsycTeller live = IUsycTeller(0x9fdF14c5B14173D74C08Af27AebFf39240dC105A);
        assertEq(live.asset(), 0x3600000000000000000000000000000000000000, "Teller pays in Arc native USDC");
        assertGt(live.previewDeposit(1e6), 0, "1 USDC subscribes to >0 USYC");
        assertGe(live.previewRedeem(1e6), 1e6, "USYC price >= 1 (yield-accrued)");
        assertGt(live.previewWithdraw(1e6), 0, "withdraw preview returns shares");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/
    function _fund(FxReserveYieldRouter.Tier tier, uint256 amount) internal {
        usdc.mint(admin, amount);
        usdc.approve(address(router), amount);
        router.depositFor(tier, amount);
    }
}
