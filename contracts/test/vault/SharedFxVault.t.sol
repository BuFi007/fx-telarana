// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {SharedFxVault} from "../../src/vault/SharedFxVault.sol";

/// @dev Borrow-free Morpho stand-in. Mints supply shares at 1e6/asset so the real
///      MorphoBalancesLib.expectedSupplyAssets() round-trips back to exactly `assets`
///      (no borrows ⇒ no interest accrual ⇒ no IRM call).
contract MockMorpho {
    using MarketParamsLib for MarketParams;

    mapping(Id => Market) internal _market;
    mapping(Id => mapping(address => Position)) internal _pos;

    function supply(MarketParams memory m, uint256 assets, uint256, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        Id id = m.id();
        IERC20(m.loanToken).transferFrom(msg.sender, address(this), assets);
        uint256 shares = assets * 1e6;
        _market[id].totalSupplyAssets += uint128(assets);
        _market[id].totalSupplyShares += uint128(shares);
        _market[id].lastUpdate = uint128(block.timestamp);
        _pos[id][onBehalf].supplyShares += shares;
        return (assets, shares);
    }

    function withdraw(MarketParams memory m, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        Id id = m.id();
        uint256 shares = assets * 1e6;
        _market[id].totalSupplyAssets -= uint128(assets);
        _market[id].totalSupplyShares -= uint128(shares);
        _pos[id][onBehalf].supplyShares -= shares;
        IERC20(m.loanToken).transfer(receiver, assets);
        return (assets, shares);
    }

    function market(Id id) external view returns (Market memory) {
        return _market[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _pos[id][user];
    }
}

/// @dev FxOracle stand-in: getMid returns a settable USDC-per-token mid (1e18 default = parity).
contract MockOracle {
    uint256 public rate = 1e18;

    function setRate(uint256 r) external {
        rate = r;
    }

    function getMid(address, address) external view returns (uint256, uint256) {
        return (rate, block.timestamp);
    }
}

contract SharedFxVaultTest is Test {
    SharedFxVault vault;
    MockERC20 usdc;
    MockERC20 eurc;
    MockMorpho morpho;
    MockOracle oracle;

    address admin = address(this);
    address timelock = makeAddr("timelock");
    address pm = makeAddr("poolManager"); // canonical v4 PoolManager
    address hook = makeAddr("hook");
    address alice = makeAddr("alice");
    address juniorFunder = makeAddr("juniorFunder");

    // Mirror of SharedFxVault's ERC-7201 namespaced storage base (private in the contract).
    bytes32 internal constant STORAGE_LOCATION =
        0x82dfe0b48341232b6b6f25f0ced28120c66a25ed3cb1d8e79e3155dc48a95300;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        morpho = new MockMorpho();
        oracle = new MockOracle();

        SharedFxVault impl = new SharedFxVault();
        MarketParams memory mkt = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(eurc),
            oracle: address(0xBEEF),
            irm: address(0xCAFE),
            lltv: 0.86e18
        });
        bytes memory initData = abi.encodeCall(
            SharedFxVault.initialize,
            (IERC20(address(usdc)), admin, timelock, pm, address(oracle), IMorpho(address(morpho)), mkt)
        );
        vault = SharedFxVault(address(new ERC1967Proxy(address(impl), initData)));

        vault.grantRole(vault.KEEPER_ROLE(), admin);
        vault.grantRole(vault.JUNIOR_ROLE(), juniorFunder);
        vault.allowHook(hook, true);
    }

    /*//////////////////////////////////////////////////////////////
                          SENIOR (ERC-4626) PATHS
    //////////////////////////////////////////////////////////////*/
    function test_seniorDepositWithdraw_pureUsdcNav() public {
        _seniorDeposit(alice, 1_000e6);
        assertEq(vault.totalAssets(), 1_000e6, "nav = deposited USDC");
        assertEq(vault.seniorUsdcHot(), 1_000e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice), 1_000e6, "full redeem");
        assertEq(vault.totalAssets(), 0);
    }

    function test_morphoRehyp_liveNavIncludesPosition() public {
        _seniorDeposit(alice, 1_000e6);
        vault.supplyIdleToMorpho(800e6);
        assertEq(vault.seniorUsdcHot(), 200e6);
        assertApproxEqAbs(vault.morphoLiveAssets(), 800e6, 1, "live morpho assets");
        assertApproxEqAbs(vault.totalAssets(), 1_000e6, 1, "nav = hot + live morpho (no stale)");

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice); // pulls shortfall from Morpho
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000e6, 1);
    }

    /*//////////////////////////////////////////////////////////////
                       JUNIOR + HOOK FILL SURFACE
    //////////////////////////////////////////////////////////////*/
    function test_fundFill_requiresHookRole() public {
        _fundJuniorUsdc(1_000e6);
        vm.expectRevert();
        vm.prank(alice);
        vault.fundFill(address(usdc), 100e6, pm);
    }

    function test_fundFill_drawsJuniorOnly_seniorUntouched() public {
        _seniorDeposit(alice, 1_000e6);
        _fundJuniorUsdc(1_000e6);
        uint256 seniorBefore = vault.seniorUsdcHot();

        vm.prank(hook);
        vault.fundFill(address(usdc), 100e6, pm);

        assertEq(vault.juniorUsdcOf(hook), 900e6, "junior debited");
        assertEq(vault.totalJuniorUsdc(), 900e6, "global total tracks the per-hook debit");
        assertEq(vault.seniorUsdcHot(), seniorBefore, "senior NEVER touched by a fill");
        assertEq(usdc.balanceOf(pm), 100e6, "output delivered to PoolManager");
    }

    function test_fundFill_rejectsWrongPoolManager() public {
        _fundJuniorUsdc(1_000e6);
        vm.prank(hook);
        vm.expectRevert(SharedFxVault.PoolManagerMismatch.selector);
        vault.fundFill(address(usdc), 100e6, address(0xDEAD)); // attacker-controlled recipient
    }

    function test_fundFill_oraclePricesFxOutNotional() public {
        // Vault prices FX-out notional itself via the oracle — the hook cannot understate it.
        oracle.setRate(1.25e18); // 1 EURC = 1.25 USDC
        _fundJuniorUsdc(1_000e6); // per-swap cap = 200e6 USDC notional
        _fundJuniorEurc(1_000e6);

        // 160 EURC out → 200 USDC notional == cap → OK
        vm.prank(hook);
        vault.fundFill(address(eurc), 160e6, pm);
        assertEq(vault.quoteUsdcNotional(address(eurc), 160e6), 200e6);

        // 161 EURC out → 201.25 USDC notional > cap → reverts (oracle, not hook, sets notional)
        vm.prank(hook);
        vm.expectRevert(SharedFxVault.PerSwapCapExceeded.selector);
        vault.fundFill(address(eurc), 161e6, pm);
    }

    function test_fundFill_perSwapCap() public {
        _fundJuniorUsdc(1_000e6); // 20% cap = 200e6
        vm.prank(hook);
        vm.expectRevert(SharedFxVault.PerSwapCapExceeded.selector);
        vault.fundFill(address(usdc), 201e6, pm);
    }

    function test_fundFill_perBlockCap_usesStartOfBlockBase() public {
        _fundJuniorUsdc(1_000e6);
        _fundJuniorEurc(1_000e6);
        vm.startPrank(hook);
        vault.fundFill(address(eurc), 200e6, pm);
        vault.fundFill(address(eurc), 200e6, pm); // 400 cumulative
        vm.expectRevert(SharedFxVault.PerBlockCapExceeded.selector);
        vault.fundFill(address(eurc), 200e6, pm); // 600 > 500 base
        vm.stopPrank();
    }

    function test_recordInflow_cannotInflateCapDenominatorMidBlock() public {
        _fundJuniorUsdc(1_000e6); // start-of-block base = 1000e6 → per-swap cap 200e6
        vm.prank(hook);
        vault.fundFill(address(eurc), 0, pm); // touch caps to snapshot base this block
        // attacker direct-sends USDC + records it to balloon juniorUsdc mid-block
        usdc.mint(address(vault), 10_000e6);
        vm.prank(hook);
        vault.recordInflow(address(usdc));
        assertEq(vault.juniorUsdcOf(hook), 11_000e6);
        // cap base is still the start-of-block snapshot, so 201e6 still exceeds per-swap cap
        vm.prank(hook);
        vm.expectRevert(SharedFxVault.PerSwapCapExceeded.selector);
        vault.fundFill(address(usdc), 201e6, pm);
    }

    function test_recordInflow_creditsJuniorBalanceBased() public {
        eurc.mint(address(vault), 137e6);
        vm.prank(hook);
        uint256 credited = vault.recordInflow(address(eurc));
        assertEq(credited, 137e6);
        assertEq(vault.juniorTokenBalanceOf(hook, address(eurc)), 137e6);
        assertEq(vault.totalJuniorTokenBalance(address(eurc)), 137e6);
    }

    function test_recordInflow_doesNotStealSeniorUsdc() public {
        _seniorDeposit(alice, 1_000e6);
        vm.prank(hook);
        uint256 credited = vault.recordInflow(address(usdc));
        assertEq(credited, 0, "senior USDC is accounted, not creditable to junior");
        assertEq(vault.juniorUsdcOf(hook), 0);
        assertEq(vault.totalJuniorUsdc(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSE / UPGRADE
    //////////////////////////////////////////////////////////////*/
    function test_pause_blocksDepositFillAndInflow() public {
        _fundJuniorUsdc(1_000e6);
        vault.pause();

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        vm.prank(hook);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.fundFill(address(usdc), 10e6, pm);

        eurc.mint(address(vault), 1e6);
        vm.prank(hook);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.recordInflow(address(eurc));
    }

    function test_upgrade_upgraderRoleIsSelfAdministered() public view {
        // UPGRADER_ROLE's admin is UPGRADER_ROLE itself, not DEFAULT_ADMIN_ROLE.
        assertEq(vault.getRoleAdmin(vault.UPGRADER_ROLE()), vault.UPGRADER_ROLE());
        assertTrue(vault.hasRole(vault.UPGRADER_ROLE(), timelock));
        assertFalse(vault.hasRole(vault.UPGRADER_ROLE(), admin));
    }

    function test_upgrade_adminCannotSelfGrantUpgrader() public {
        // admin holds DEFAULT_ADMIN_ROLE but its admin over UPGRADER_ROLE was revoked
        // by locking UPGRADER_ROLE's admin to itself → cannot self-grant the upgrade key.
        bytes32 upgrader = vault.UPGRADER_ROLE(); // cache: expectRevert binds to the NEXT call
        vm.expectRevert();
        vault.grantRole(upgrader, admin);
    }

    function test_upgrade_adminCannotUpgrade() public {
        address v2 = address(new SharedFxVault());
        vm.expectRevert();
        vault.upgradeToAndCall(v2, "");
    }

    function test_upgrade_timelockCanUpgrade() public {
        address v2 = address(new SharedFxVault());
        vm.prank(timelock);
        vault.upgradeToAndCall(v2, "");
    }

    /*//////////////////////////////////////////////////////////////
                       PER-HOOK ALLOCATION (Codex HIGH#1)
    //////////////////////////////////////////////////////////////*/

    /// @dev One pool's junior slice cannot be drained to fund another pool. Fund hookA's USDC
    ///      slice; a DIFFERENT allowlisted hookB's fundFill reverts (its slice is empty) even
    ///      though the vault holds hookA's USDC.
    function test_perHookAllocation_isolated() public {
        address hookB = makeAddr("hookB");
        vault.allowHook(hookB, true);

        // Fund ONLY hookA (== `hook`)'s USDC slice.
        _fundJuniorUsdcFor(hook, 1_000e6);
        assertEq(vault.juniorUsdcOf(hook), 1_000e6);
        assertEq(vault.juniorUsdcOf(hookB), 0, "hookB slice empty");
        assertEq(vault.totalJuniorUsdc(), 1_000e6, "global total only reflects hookA");

        // hookB tries to fund a fill against an EMPTY slice. Its per-swap cap base is its OWN
        // (zero) slice, so the very first guard — the cap on a 0 denominator — reverts. hookB
        // can NEVER reach hookA's 1_000e6 even though the vault physically holds it.
        vm.prank(hookB);
        vm.expectRevert(SharedFxVault.PerSwapCapExceeded.selector);
        vault.fundFill(address(usdc), 1e6, pm);

        // Even if hookB is given a small slice (so it clears its own cap), it still cannot debit
        // more than ITS OWN slice — the JuniorUsdcShort guard caps it at its allocation, never
        // hookA's. Fund hookB 10e6 → cap allows up to 2e6 (20%), but a 5e6 attempt to reach into
        // the shared pool is bounded first by its cap.
        _fundJuniorUsdcFor(hookB, 10e6);
        vm.prank(hookB);
        vm.expectRevert(SharedFxVault.PerSwapCapExceeded.selector);
        vault.fundFill(address(usdc), 5e6, pm); // 5e6 > 20% * 10e6 = 2e6 cap (its own slice)

        // hookB spends within its OWN slice fine; hookA's slice is untouched throughout.
        vm.prank(hookB);
        vault.fundFill(address(usdc), 2e6, pm);
        assertEq(vault.juniorUsdcOf(hookB), 8e6, "hookB debited from its own slice");
        assertEq(vault.juniorUsdcOf(hook), 1_000e6, "hookA slice NEVER drained by hookB");

        // hookA can still spend its own slice in full.
        vm.prank(hook);
        vault.fundFill(address(usdc), 100e6, pm);
        assertEq(vault.juniorUsdcOf(hook), 900e6);
        assertEq(vault.totalJuniorUsdc(), 908e6, "global = hookA 900 + hookB 8");
    }

    /// @dev Legacy GLOBAL junior (pre-allocation deployment) migrates into a hook's slice +
    ///      global totals, legacy globals zeroed, and cannot be migrated twice.
    function test_migrateLegacyJuniorToHook() public {
        // Simulate a legacy global junior buffer by writing the legacy scalar/mapping slots
        // directly (these are no longer reachable via fundJunior after the per-hook refactor).
        // Legacy juniorUsdc lives at struct offset 4; juniorToken mapping at offset 5.
        // VaultStorage field offsets from STORAGE_LOCATION:
        //   0: morpho | 1-5: morphoMarket (MarketParams, 5 slots) | 6: morphoSupplied
        //   7: seniorUsdcHot | 8: juniorUsdc | 9: juniorToken (mapping)
        uint256 base = uint256(STORAGE_LOCATION);
        uint256 LEGACY_JUNIOR_USDC = 8;
        uint256 LEGACY_JUNIOR_TOKEN = 9;
        vm.store(address(vault), bytes32(base + LEGACY_JUNIOR_USDC), bytes32(uint256(10_100e6)));
        // juniorToken[eurc] mapping slot = keccak256(key . mappingSlot)
        bytes32 eurcSlot = keccak256(abi.encode(address(eurc), bytes32(base + LEGACY_JUNIOR_TOKEN)));
        vm.store(address(vault), eurcSlot, bytes32(uint256(9_090e6)));

        address eurcHook = makeAddr("eurcHook");
        vault.allowHook(eurcHook, true); // migration target must be allowlisted
        address[] memory tokens = new address[](1);
        tokens[0] = address(eurc);

        // STEAL-WINDOW GUARD: before migration, the legacy balances are unaccounted; an allowlisted
        // hook must NOT be able to sweep them via recordInflow.
        vm.prank(eurcHook);
        vm.expectRevert(SharedFxVault.LegacyNotMigrated.selector);
        vault.recordInflow(address(usdc));
        vm.prank(eurcHook);
        vm.expectRevert(SharedFxVault.LegacyNotMigrated.selector);
        vault.recordInflow(address(eurc));

        vault.migrateLegacyJuniorToHook(eurcHook, tokens);

        // Per-hook slice + global totals correct.
        assertEq(vault.juniorUsdcOf(eurcHook), 10_100e6, "USDC migrated to hook slice");
        assertEq(vault.juniorTokenBalanceOf(eurcHook, address(eurc)), 9_090e6, "EURC migrated");
        assertEq(vault.totalJuniorUsdc(), 10_100e6, "global USDC total");
        assertEq(vault.totalJuniorTokenBalance(address(eurc)), 9_090e6, "global EURC total");

        // Legacy globals zeroed.
        assertEq(uint256(vm.load(address(vault), bytes32(base + LEGACY_JUNIOR_USDC))), 0, "legacy juniorUsdc zeroed");
        assertEq(uint256(vm.load(address(vault), eurcSlot)), 0, "legacy juniorToken zeroed");

        // Idempotent: re-calling moves nothing (legacy already zeroed), slice unchanged.
        vault.migrateLegacyJuniorToHook(eurcHook, tokens);
        assertEq(vault.juniorUsdcOf(eurcHook), 10_100e6, "no double-credit on re-migrate");
        assertEq(vault.totalJuniorUsdc(), 10_100e6, "no double-credit to total");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/
    function _seniorDeposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _fundJuniorUsdc(uint256 amount) internal {
        _fundJuniorUsdcFor(hook, amount);
    }

    function _fundJuniorEurc(uint256 amount) internal {
        _fundJuniorEurcFor(hook, amount);
    }

    function _fundJuniorUsdcFor(address h, uint256 amount) internal {
        usdc.mint(juniorFunder, amount);
        vm.startPrank(juniorFunder);
        usdc.approve(address(vault), amount);
        vault.fundJunior(h, address(usdc), amount);
        vm.stopPrank();
    }

    function _fundJuniorEurcFor(address h, uint256 amount) internal {
        eurc.mint(juniorFunder, amount);
        vm.startPrank(juniorFunder);
        eurc.approve(address(vault), amount);
        vault.fundJunior(h, address(eurc), amount);
        vm.stopPrank();
    }
}
