// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams as MorphoMarketParams, Id as MorphoId} from "morpho-blue/interfaces/IMorpho.sol";

import {FxPrivacyPool} from "../src/hub/FxPrivacyPool.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

import {Constants} from "privacy-pools/contracts/lib/Constants.sol";
import {IPrivacyPool} from "privacy-pools/interfaces/IPrivacyPool.sol";
import {IState} from "privacy-pools/interfaces/IState.sol";
import {IVerifier} from "privacy-pools/interfaces/IVerifier.sol";

/// @notice Stub Groth16 verifier that always passes — slice-1 tests assert
///         contract plumbing (state transitions, access control, asset flow)
///         not the underlying ZK proof. Real proof verification is exercised
///         in slice-4 SDK tests once the snarkjs witness pipeline lands.
contract MockVerifier is IVerifier {
    function verifyProof(
        uint256[2] memory,
        uint256[2][2] memory,
        uint256[2] memory,
        uint256[8] memory
    ) external pure returns (bool) {
        return true;
    }

    function verifyProof(
        uint256[2] memory,
        uint256[2][2] memory,
        uint256[2] memory,
        uint256[4] memory
    ) external pure returns (bool) {
        return true;
    }
}

/// @notice Tiny mock Morpho that round-trips supply/withdraw 1:1 in shares,
///         tracks balances, and lets slice-2 unit tests assert the rehyp
///         pattern without forking mainnet.
contract MockMorpho {
    mapping(address loanToken => mapping(address user => uint256)) public supplyAssetsOf;
    uint256 public supplyCalls;
    uint256 public withdrawCalls;

    function supply(
        MorphoMarketParams memory _mp,
        uint256 _assets,
        uint256,
        address _onBehalf,
        bytes memory
    ) external returns (uint256, uint256) {
        IERC20(_mp.loanToken).transferFrom(msg.sender, address(this), _assets);
        supplyAssetsOf[_mp.loanToken][_onBehalf] += _assets;
        ++supplyCalls;
        return (_assets, _assets); // shares = assets 1:1
    }

    function withdraw(
        MorphoMarketParams memory _mp,
        uint256 _assets,
        uint256 _shares,
        address _onBehalf,
        address _receiver
    ) external returns (uint256, uint256) {
        // Mock-Morpho is 1:1 (shares = assets). Real Morpho rejects both
        // non-zero; tests don't exercise that path.
        uint256 amount = _assets > 0 ? _assets : _shares;
        require(supplyAssetsOf[_mp.loanToken][_onBehalf] >= amount, "insufficient");
        supplyAssetsOf[_mp.loanToken][_onBehalf] -= amount;
        IERC20(_mp.loanToken).transfer(_receiver, amount);
        ++withdrawCalls;
        return (amount, amount);
    }

    function expectedSupplyAssets(MorphoMarketParams memory _mp, address _user) external view returns (uint256) {
        return supplyAssetsOf[_mp.loanToken][_user];
    }

    function market(MorphoId) external pure returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }

    /// @notice MorphoBalancesLib.expectedSupplyAssets() reads storage via
    ///         extSloads. Returning zero-slot reads means the helper computes
    ///         expectedSupplyAssets = 0 — slice-2 unit tests therefore assert
    ///         rehyp via the mock's `supplyAssetsOf` mapping (and `supplyCalls`
    ///         counter) rather than the pool's view. Real interest accounting
    ///         is exercised in the mainnet fork test.
    function extSloads(bytes32[] calldata slots) external pure returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        // all zero
    }
}

/// @notice Mock registry that returns canned MarketParams for the (loan,
///         collateral) lookup. Loan=ASSET, collateral=COLLATERAL; all
///         other fields (oracle, irm, lltv) are inert in mock-Morpho's
///         supply/withdraw — they only matter on the real protocol.
contract MockMarketRegistry is IFxMarketRegistry {
    function paramsOf(address loanToken, address collateralToken)
        external
        pure
        returns (MarketParams memory)
    {
        return MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: address(0x1),
            irm:    address(0x2),
            lltv:   86e16
        });
    }

    // Inert stubs — slice-2 tests only exercise `paramsOf`.
    function marketIdOf(address, address) external pure returns (bytes32) { return bytes32(0); }
    function listPools() external pure returns (MarketParams[] memory empty) { return empty; }
    function isPoolLive(address, address) external pure returns (bool) { return true; }
    function setPoolLive(address, address, bool) external {}
    function borrowDelegateOf(address, address) external pure returns (bool) { return false; }
    function setBorrowDelegate(address, bool) external {}
    function supply(address, address, uint256, address) external pure returns (uint256) { return 0; }
    function withdraw(address, address, uint256, address, address) external pure returns (uint256) { return 0; }
    function supplyCollateral(address, address, uint256, address) external {}
    function withdrawCollateral(address, address, uint256, address, address) external {}
    function borrow(address, address, uint256, address, address) external pure returns (uint256) { return 0; }
    function borrowDelegated(address, address, uint256, address, address) external pure returns (uint256) { return 0; }
    function repay(address, address, uint256, address) external pure returns (uint256) { return 0; }
}

contract FxPrivacyPoolTest is Test {
    address constant ENTRYPOINT = address(0x1111);
    address constant OWNER      = address(0xABCD);
    address constant USER       = address(0xBEEF);

    MockStablecoin       internal usdc;
    MockStablecoin       internal eurc; // collateral side
    MockVerifier         internal withdrawalVerifier;
    MockVerifier         internal ragequitVerifier;
    MockMorpho           internal morpho;
    MockMarketRegistry   internal registry;
    FxPrivacyPool        internal pool;

    function setUp() public {
        usdc = new MockStablecoin("USD Coin", "USDC", 6, address(this));
        eurc = new MockStablecoin("EUR Coin", "EURC", 6, address(this));

        withdrawalVerifier = new MockVerifier();
        ragequitVerifier   = new MockVerifier();
        morpho             = new MockMorpho();
        registry           = new MockMarketRegistry();

        pool = new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            OWNER,
            address(morpho),
            address(registry),
            address(eurc)
        );

        usdc.mint(ENTRYPOINT, 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnNativeAsset() public {
        vm.expectRevert(); // NativeAssetNotSupported() on IPrivacyPoolComplex
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            Constants.NATIVE_ASSET,
            OWNER,
            address(morpho),
            address(registry),
            address(eurc)
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            address(0),
            address(morpho),
            address(registry),
            address(eurc)
        );
    }

    function test_constructor_revertsOnZeroMorpho() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            OWNER,
            address(0),
            address(registry),
            address(eurc)
        );
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            OWNER,
            address(morpho),
            address(0),
            address(eurc)
        );
    }

    function test_constructor_revertsOnZeroCollateral() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            OWNER,
            address(morpho),
            address(registry),
            address(0)
        );
    }

    function test_constructor_revertsWhenCollateralEqualsAsset() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        new FxPrivacyPool(
            ENTRYPOINT,
            address(withdrawalVerifier),
            address(ragequitVerifier),
            address(usdc),
            OWNER,
            address(morpho),
            address(registry),
            address(usdc)
        );
    }

    function test_constructor_setsImmutablesAndDefaults() public view {
        assertEq(pool.ASSET(),                        address(usdc));
        assertEq(address(pool.ENTRYPOINT()),          ENTRYPOINT);
        assertEq(address(pool.WITHDRAWAL_VERIFIER()), address(withdrawalVerifier));
        assertEq(address(pool.RAGEQUIT_VERIFIER()),   address(ragequitVerifier));
        assertEq(pool.owner(),                        OWNER);
        assertEq(address(pool.MORPHO()),              address(morpho));
        assertEq(address(pool.REGISTRY()),            address(registry));
        assertEq(pool.COLLATERAL(),                   address(eurc));
        assertEq(pool.hotReservePct(),                pool.DEFAULT_HOT_RESERVE_PCT());
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function test_transferOwner_succeedsForOwner() public {
        address newOwner = address(0xCAFE);
        vm.prank(OWNER);
        pool.transferOwner(newOwner);
        assertEq(pool.owner(), newOwner);
    }

    function test_transferOwner_revertsForNonOwner() public {
        vm.expectRevert(FxPrivacyPool.NotOwner.selector);
        vm.prank(USER);
        pool.transferOwner(USER);
    }

    function test_transferOwner_revertsForZeroAddress() public {
        vm.expectRevert(IState.ZeroAddress.selector);
        vm.prank(OWNER);
        pool.transferOwner(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          HOT RESERVE PCT
    //////////////////////////////////////////////////////////////*/

    function test_setHotReservePct_succeedsForOwner() public {
        vm.prank(OWNER);
        pool.setHotReservePct(5_000);
        assertEq(pool.hotReservePct(), 5_000);
    }

    function test_setHotReservePct_revertsForNonOwner() public {
        vm.expectRevert(FxPrivacyPool.NotOwner.selector);
        vm.prank(USER);
        pool.setHotReservePct(5_000);
    }

    function test_setHotReservePct_revertsAboveBpsDenom() public {
        vm.expectRevert(FxPrivacyPool.InvalidHotReservePct.selector);
        vm.prank(OWNER);
        pool.setHotReservePct(10_001);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT (via Entrypoint)
    //////////////////////////////////////////////////////////////*/

    function test_deposit_revertsForNonEntrypoint() public {
        vm.expectRevert(IState.OnlyEntrypoint.selector);
        vm.prank(USER);
        pool.deposit(USER, 100e6, _fakePrecommitment(1));
    }

    /// @dev Slice 2: deposit at default 20% hot leaves 20% in pool, 80% in
    ///      Morpho. NB: pool.morphoSupplyAssets() returns 0 in this mock
    ///      because MorphoBalancesLib uses extSloads (returns zero here);
    ///      we assert the rehyp via the mock's `supplyAssetsOf` instead.
    ///      The mainnet fork test covers the live `expectedSupplyAssets` path.
    function test_deposit_splitsHotAndMorpho() public {
        uint256 amount = 100e6;
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), amount);
        uint256 commitment = pool.deposit(USER, amount, _fakePrecommitment(2));
        vm.stopPrank();

        assertGt(commitment, 0);
        // Default hotReservePct = 2000 bps (20%).
        assertEq(usdc.balanceOf(address(pool)),                       20e6, "hot reserve");
        assertEq(morpho.supplyAssetsOf(address(usdc), address(pool)), 80e6, "morpho supply (mock)");
        assertEq(morpho.supplyCalls(),                                1,    "one supply call");
        assertEq(pool.morphoShares(),                                 80e6, "shares 1:1");
    }

    /// @dev With hotReservePct=10_000 (full hot), no Morpho call.
    function test_deposit_atFullHot_doesNotTouchMorpho() public {
        vm.prank(OWNER);
        pool.setHotReservePct(10_000);

        uint256 amount = 50e6;
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), amount);
        pool.deposit(USER, amount, _fakePrecommitment(3));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(pool)), amount);
        assertEq(pool.morphoShares(),           0);
        assertEq(morpho.supplyCalls(),          0);
    }

    function test_deposit_revertsWhenDead() public {
        vm.prank(ENTRYPOINT);
        pool.windDown();

        vm.expectRevert(IState.PoolIsDead.selector);
        vm.prank(ENTRYPOINT);
        pool.deposit(USER, 100e6, _fakePrecommitment(4));
    }

    function test_deposit_revertsOnValueOverflow() public {
        vm.expectRevert(IPrivacyPool.InvalidDepositValue.selector);
        vm.prank(ENTRYPOINT);
        pool.deposit(USER, type(uint128).max, _fakePrecommitment(5));
    }

    /*//////////////////////////////////////////////////////////////
                          MORPHO REHYPOTHECATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Multi-deposit ratio invariance requires accurate
    ///      MorphoBalancesLib.expectedSupplyAssets accounting (which depends
    ///      on real interest-accrual storage layout). Covered by the
    ///      mainnet fork test, not here — see test/MainnetFork.t.sol.

    /// @dev setHotReservePct that lowers the hot target rebalances into
    ///      Morpho on the next interaction.
    /// @dev codex-r1 MED #1 regression: setting hotPct to 100% must unwind
    ///      existing Morpho supply, not leave it stranded.
    function test_setHotReservePct_fullHotUnwindsMorpho() public {
        uint256 amount = 100e6;
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), amount);
        pool.deposit(USER, amount, _fakePrecommitment(10));
        vm.stopPrank();

        // Default 20% hot → 80% landed in Morpho.
        assertEq(morpho.supplyAssetsOf(address(usdc), address(pool)), 80e6, "supplied before");
        assertEq(usdc.balanceOf(address(pool)),                       20e6, "hot before");

        // Tighten to 100% hot — should fully unwind.
        vm.prank(OWNER);
        pool.setHotReservePct(10_000);

        assertEq(morpho.supplyAssetsOf(address(usdc), address(pool)), 0,      "morpho unwound");
        assertEq(usdc.balanceOf(address(pool)),                       100e6,  "all hot");
        assertEq(pool.morphoShares(),                                 0,      "shares burned");
    }

    function test_setHotReservePct_triggersRebalance() public {
        vm.prank(OWNER);
        pool.setHotReservePct(10_000); // 100% hot

        uint256 amount = 100e6;
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), amount);
        pool.deposit(USER, amount, _fakePrecommitment(6));
        vm.stopPrank();
        assertEq(morpho.supplyCalls(), 0);

        vm.prank(OWNER);
        pool.setHotReservePct(2_000); // 20% hot — triggers rebalance
        assertEq(usdc.balanceOf(address(pool)),                       20e6);
        assertEq(morpho.supplyAssetsOf(address(usdc), address(pool)), 80e6);
        assertEq(morpho.supplyCalls(),                                1);
    }

    /*//////////////////////////////////////////////////////////////
                          WIND DOWN
    //////////////////////////////////////////////////////////////*/

    function test_windDown_revertsForNonEntrypoint() public {
        vm.expectRevert(IState.OnlyEntrypoint.selector);
        vm.prank(OWNER);
        pool.windDown();
    }

    function test_windDown_setsDead() public {
        vm.prank(ENTRYPOINT);
        pool.windDown();
        assertTrue(pool.dead());
    }

    function test_windDown_revertsIfAlreadyDead() public {
        vm.prank(ENTRYPOINT);
        pool.windDown();

        vm.expectRevert(IState.PoolIsDead.selector);
        vm.prank(ENTRYPOINT);
        pool.windDown();
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE ASSET REJECTION
    //////////////////////////////////////////////////////////////*/

    function test_deposit_rejectsNativeValue() public {
        vm.deal(ENTRYPOINT, 1 ether);
        vm.startPrank(ENTRYPOINT);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(); // NativeAssetNotAccepted (IPrivacyPoolComplex error)
        pool.deposit{value: 1}(USER, 100e6, _fakePrecommitment(7));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fakePrecommitment(uint256 salt) internal pure returns (uint256) {
        // Any non-zero field-fitting value works for the deposit codepath.
        return uint256(keccak256(abi.encode("precommitment", salt))) %
               Constants.SNARK_SCALAR_FIELD;
    }
}
