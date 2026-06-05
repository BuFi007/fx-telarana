// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {TurboFeeVault} from "../../src/hub/TurboFeeVault.sol"; // REAL contract under test
import {ITurboFeeVault} from "../../src/interfaces/ITurboFeeVault.sol";
import {FxYieldRelay, IHubRelay} from "../../src/hub/FxYieldRelay.sol";

/// @dev The cross-hub send boundary. `relayToRemoteHub` physically targets another chain (Gateway
///      burn → off-chain attestation → mint on the remote hub), which cannot exist in a single-fork
///      unit test. This faithful stand-in mirrors the REAL FxHubMessageReceiver.relayToRemoteHub
///      observable behavior: it pulls USDC from the caller. (This is NOT a Morpho mock.)
contract MockHubRelay is IHubRelay {
    IERC20 public usdc;
    uint256 public received;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function relayToRemoteHub(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

contract FxYieldRelayTest is Test {
    MockERC20 usdc;
    TurboFeeVault feeVault; // REAL
    FxYieldRelay relay;
    MockHubRelay hub;

    address admin = address(this);
    address treasury = makeAddr("treasury");
    address depositor = makeAddr("feeDepositor");
    address spoke = makeAddr("spokeAdapter");

    uint32 constant FUJI = 43113;
    bytes32 constant MARKET = keccak256("EURC/USDC");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        feeVault = new TurboFeeVault(IERC20(address(usdc)), treasury);
        relay = new FxYieldRelay(IERC20(address(usdc)), ITurboFeeVault(address(feeVault)), admin);
        hub = new MockHubRelay(IERC20(address(usdc)));

        relay.setHub(IHubRelay(address(hub)));
        relay.grantRole(relay.SPOKE_ROLE(), spoke);
        feeVault.grantRole(feeVault.FEE_DEPOSITOR_ROLE(), depositor);
    }

    /*//////////////////////////////////////////////////////////////
                       SINGLE CROSS-HUB LP — FULL FLOW
    //////////////////////////////////////////////////////////////*/

    function test_p3_singleLp_stakeEarnClaimHome() public {
        _stake(spoke, FUJI, alice(), 1_000e6);

        _depositFee(100e6); // 50 protocol / 40 LP / 10 insurance → relay (sole staker) earns 40

        assertEq(relay.pendingYieldFor(FUJI, alice()), 40e6, "LP fee share accrued");

        uint256 amt = relay.claimYieldFor(FUJI, alice());
        assertEq(amt, 40e6, "claimed LP yield");
        assertEq(hub.received(), 40e6, "yield pushed to home hub via Gateway rail");
        assertEq(relay.pendingYieldFor(FUJI, alice()), 0, "drained");
    }

    /*//////////////////////////////////////////////////////////////
                  MULTIPLE CROSS-HUB LPs — PRO-RATA SPLIT
    //////////////////////////////////////////////////////////////*/

    function test_p3_multiLp_proRataSplit() public {
        _stake(spoke, FUJI, alice(), 1_000e6);
        _stake(spoke, FUJI, bob(), 1_000e6);

        _depositFee(100e6); // LP share 40 split 20/20 across equal stakes

        assertEq(relay.pendingYieldFor(FUJI, alice()), 20e6);
        assertEq(relay.pendingYieldFor(FUJI, bob()), 20e6);

        relay.claimYieldFor(FUJI, alice());
        relay.claimYieldFor(FUJI, bob());
        assertEq(hub.received(), 40e6, "both LPs delivered home");
        assertEq(relay.pendingYieldFor(FUJI, alice()), 0);
        assertEq(relay.pendingYieldFor(FUJI, bob()), 0);
    }

    /// @dev Yield earned BEFORE a second LP joins is not diluted to the latecomer.
    function test_p3_lateJoiner_doesNotStealPriorYield() public {
        _stake(spoke, FUJI, alice(), 1_000e6);
        _depositFee(100e6); // alice alone earns 40

        _stake(spoke, FUJI, bob(), 1_000e6); // bob joins after
        assertEq(relay.pendingYieldFor(FUJI, alice()), 40e6, "alice keeps pre-join yield");
        assertEq(relay.pendingYieldFor(FUJI, bob()), 0, "bob earns nothing retroactively");

        _depositFee(100e6); // now split 20/20
        assertEq(relay.pendingYieldFor(FUJI, alice()), 60e6);
        assertEq(relay.pendingYieldFor(FUJI, bob()), 20e6);
    }

    /*//////////////////////////////////////////////////////////////
                          UNSTAKE → HOME
    //////////////////////////////////////////////////////////////*/

    function test_p3_unstakePushesPrincipalHome() public {
        uint256 sub = _stake(spoke, FUJI, alice(), 1_000e6);
        vm.prank(spoke);
        uint256 assets = relay.unstakeFor(FUJI, alice(), sub);
        assertEq(assets, 1_000e6, "principal withdrawn from TurboFeeVault");
        assertEq(hub.received(), 1_000e6, "principal pushed to home hub");
    }

    /*//////////////////////////////////////////////////////////////
                       COMPLIANCE — RWA-clean surface
    //////////////////////////////////////////////////////////////*/

    /// @dev The relay only ever moves USDC trading-fee yield out of TurboFeeVault — no USYC, no Teller,
    ///      no router. The value delivered equals the TurboFeeVault LP fee share, nothing else.
    function test_p3_rwaClean_deliversOnlyFeeYield() public {
        _stake(spoke, FUJI, alice(), 1_000e6);
        _depositFee(250e6); // LP share = 40% = 100
        uint256 amt = relay.claimYieldFor(FUJI, alice());
        assertEq(amt, 100e6, "delivered == TurboFeeVault LP fee share (USDC), nothing else");
        assertEq(address(relay.USDC()), address(usdc), "relay's only asset is USDC");
    }

    /*//////////////////////////////////////////////////////////////
                              ACCESS / GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_p3_onlySpokeCanStake() public {
        usdc.mint(address(this), 100e6);
        usdc.approve(address(relay), 100e6);
        vm.expectRevert();
        relay.stakeFor(FUJI, alice(), 100e6); // not SPOKE_ROLE
    }

    function test_p3_claimRevertsWhenNothing() public {
        _stake(spoke, FUJI, alice(), 1_000e6);
        vm.expectRevert(FxYieldRelay.NothingToClaim.selector);
        relay.claimYieldFor(FUJI, alice());
    }

    function test_p3_claimIsPermissionless() public {
        _stake(spoke, FUJI, alice(), 1_000e6);
        _depositFee(100e6);
        vm.prank(makeAddr("anyone")); // not the LP, not a spoke
        relay.claimYieldFor(FUJI, alice()); // funds can only go to alice's home → safe
        assertEq(hub.received(), 40e6);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/
    function alice() internal returns (address) {
        return makeAddr("alice");
    }

    function bob() internal returns (address) {
        return makeAddr("bob");
    }

    function _stake(address from, uint32 chain, address lp, uint256 amount) internal returns (uint256) {
        usdc.mint(from, amount);
        vm.startPrank(from);
        usdc.approve(address(relay), amount);
        uint256 sub = relay.stakeFor(chain, lp, amount);
        vm.stopPrank();
        return sub;
    }

    function _depositFee(uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(feeVault), amount);
        feeVault.depositFee(address(usdc), amount, MARKET);
        vm.stopPrank();
    }
}
