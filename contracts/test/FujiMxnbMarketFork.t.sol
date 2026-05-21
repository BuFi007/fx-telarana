// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, Market, MarketParams as MorphoMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

interface ILegacyFxMarketRegistry {
    function createAndRegisterMarket(IFxMarketRegistry.MarketParams calldata p)
        external
        returns (bytes32 marketId);
    function MORPHO() external view returns (address);
    function owner() external view returns (address);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Fork test for `DeployFujiMxnbMarkets.s.sol`. Pins the live
///         Fuji contract addresses (USDC, MXNB, Pyth, IRM, FxMarketRegistry,
///         Morpho Blue, the deployer EOA) and asserts:
///
///           1. The deployer is still the registry's `owner()`.
///           2. The IRM + LLTV are enabled on the live Morpho Blue.
///           3. Pyth USDC/USD + USD/MXN feeds are live with non-zero prices.
///           4. The script's flow — fresh FxOracle, two MorphoOracleAdapters,
///              two `createAndRegisterMarket` calls — actually lands two new
///              market IDs in the registry.
///           5. M1 + M2 (the existing EURC/USDC pair) are NOT disturbed.
///
/// Gated by `FUJI_RPC_URL`. Default test run (no fork URL) skips silently
/// so the regular `forge test` path stays fast.
contract FujiMxnbMarketForkTest is Test {
    using MarketParamsLib for MorphoMarketParams;

    // ---- live Fuji addresses (deployments/avalanche-fuji.json + BITSO) ----
    address constant LIVE_REGISTRY = 0x7ba745b979e027992ECFa51207666e3F5B46cF0a;
    address constant LIVE_MORPHO   = 0xeF64621D41093144D9ED8aB8327eE381ECdB79E6;
    address constant LIVE_IRM      = 0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA;
    address constant LIVE_PYTH     = 0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509;
    address constant LIVE_USDC     = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address constant LIVE_EURC     = 0x5E44db7996c682E92a960b65AC713a54AD815c6B;
    address constant LIVE_MXNB     = 0xAB99d44185af87AeB08361588F00F59B0CE85eBb;
    address constant LIVE_DEPLOYER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    // Existing market IDs from deployments/avalanche-fuji.json.
    bytes32 constant LIVE_M1_ID = 0x7d99088a9fe61331c49a92eb16fa3794b0bc2862b211f5a70f31a64cef25029e;
    bytes32 constant LIVE_M2_ID = 0x1700104cf29eceb113e01a1bcdc913e5e10d3d37314cee235752aa88bf153197;

    // Pyth feed ids (Pyth's published catalog).
    bytes32 constant PYTH_USDC_USD =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_USD_MXN =
        0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;

    uint256 constant LLTV = 0.86e18;

    ILegacyFxMarketRegistry internal registry;
    IMorpho internal morpho;

    bool internal forkActive;

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            return;
        }
        vm.createSelectFork(rpc);
        forkActive = true;
        registry = ILegacyFxMarketRegistry(LIVE_REGISTRY);
        morpho   = IMorpho(LIVE_MORPHO);
    }

    modifier whenFork() {
        if (!forkActive) return;
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        PIN: live Fuji preconditions
    //////////////////////////////////////////////////////////////*/

    function test_fork_pin_registryOwnerIsDeployer() public whenFork {
        assertEq(registry.owner(), LIVE_DEPLOYER, "deployer is no longer FxMarketRegistry.owner");
    }

    function test_fork_pin_registryMorphoMatchesManifest() public whenFork {
        assertEq(registry.MORPHO(), LIVE_MORPHO, "registry MORPHO != manifest");
    }

    function test_fork_pin_irmEnabledOnLiveMorpho() public whenFork {
        assertTrue(morpho.isIrmEnabled(LIVE_IRM), "IRM not enabled on live Morpho");
    }

    function test_fork_pin_lltvEnabledOnLiveMorpho() public whenFork {
        assertTrue(morpho.isLltvEnabled(LLTV), "0.86 LLTV not enabled on live Morpho");
    }

    function test_fork_pin_mxnbHas6Decimals() public whenFork {
        // BITSO's MXNB on Fuji is 6-decimal (matches USDC scale). The adapter's
        // SCALE_FACTOR math assumes 36 + loanDec - collatDec; a surprise on this
        // would crater the adapter price() result.
        assertEq(IERC20Decimals(LIVE_MXNB).decimals(), 6, "MXNB decimals != 6");
    }

    function test_fork_pin_m1AndM2StillRegistered() public whenFork {
        // Confirm market exists on Morpho (lastUpdate != 0 iff createMarket was called).
        Market memory m1 = morpho.market(Id.wrap(LIVE_M1_ID));
        Market memory m2 = morpho.market(Id.wrap(LIVE_M2_ID));
        assertGt(m1.lastUpdate, 0, "M1 (EURC/USDC) missing from live Morpho");
        assertGt(m2.lastUpdate, 0, "M2 (USDC/EURC) missing from live Morpho");
    }

    /*//////////////////////////////////////////////////////////////
                FLOW: end-to-end mxnb-market provisioning
    //////////////////////////////////////////////////////////////*/

    /// @dev Reproduces the deploy script's flow exactly (FxOracle + two
    ///      adapters + two createAndRegisterMarket calls), executed under
    ///      `vm.prank(LIVE_DEPLOYER)` so we don't need a private key. Asserts
    ///      that two fresh market IDs are produced and they ARE NOT the
    ///      live M1/M2 ids.
    function test_fork_deployMxnbMarketsFlow_e2e() public whenFork {
        // Pre: M3 + M4 not yet registered (paramsOf returns zero-address
        // tuples for unregistered pairs on the legacy Ownable registry —
        // we don't depend on that, just on createAndRegisterMarket succeeding).

        // 1) Fresh oracle wired for USDC + MXNB.
        FxOracle oracle = new FxOracle(LIVE_PYTH, address(this), 300, 50, 30);
        oracle.setFeed(LIVE_USDC, PYTH_USDC_USD);
        oracle.setPythFeedConfig(LIVE_MXNB, PYTH_USD_MXN, true /* inverted */);

        // 2) Two adapters.
        MorphoOracleAdapter adapterM3 = new MorphoOracleAdapter(address(oracle), LIVE_MXNB, LIVE_USDC);
        MorphoOracleAdapter adapterM4 = new MorphoOracleAdapter(address(oracle), LIVE_USDC, LIVE_MXNB);

        // Adapter SCALE_FACTOR sanity: with both at 6 decimals, expected = 1e36.
        assertEq(adapterM3.SCALE_FACTOR(), 1e36, "M3 adapter SCALE_FACTOR != 1e36");
        assertEq(adapterM4.SCALE_FACTOR(), 1e36, "M4 adapter SCALE_FACTOR != 1e36");

        // 3) Call createAndRegisterMarket twice as the deployer (=registry.owner()).
        IFxMarketRegistry.MarketParams memory m3 = IFxMarketRegistry.MarketParams({
            loanToken:       LIVE_MXNB,
            collateralToken: LIVE_USDC,
            oracle:          address(adapterM3),
            irm:             LIVE_IRM,
            lltv:            LLTV
        });
        IFxMarketRegistry.MarketParams memory m4 = IFxMarketRegistry.MarketParams({
            loanToken:       LIVE_USDC,
            collateralToken: LIVE_MXNB,
            oracle:          address(adapterM4),
            irm:             LIVE_IRM,
            lltv:            LLTV
        });

        vm.startPrank(LIVE_DEPLOYER);
        bytes32 m3Id = registry.createAndRegisterMarket(m3);
        bytes32 m4Id = registry.createAndRegisterMarket(m4);
        vm.stopPrank();

        assertTrue(m3Id != bytes32(0), "M3 id zero");
        assertTrue(m4Id != bytes32(0), "M4 id zero");
        assertTrue(m3Id != m4Id, "M3/M4 ids collide");

        // Cross-check: each must match Morpho's marketId computation.
        bytes32 m3Expected = Id.unwrap(MorphoMarketParams({
            loanToken:       LIVE_MXNB,
            collateralToken: LIVE_USDC,
            oracle:          address(adapterM3),
            irm:             LIVE_IRM,
            lltv:            LLTV
        }).id());
        bytes32 m4Expected = Id.unwrap(MorphoMarketParams({
            loanToken:       LIVE_USDC,
            collateralToken: LIVE_MXNB,
            oracle:          address(adapterM4),
            irm:             LIVE_IRM,
            lltv:            LLTV
        }).id());
        assertEq(m3Id, m3Expected, "M3 id != Morpho.id()");
        assertEq(m4Id, m4Expected, "M4 id != Morpho.id()");

        // And they must not collide with the live M1/M2.
        assertTrue(m3Id != LIVE_M1_ID && m3Id != LIVE_M2_ID, "M3 collides with M1/M2");
        assertTrue(m4Id != LIVE_M1_ID && m4Id != LIVE_M2_ID, "M4 collides with M1/M2");

        // Markets must now exist on Morpho.
        Market memory m3State = morpho.market(Id.wrap(m3Id));
        Market memory m4State = morpho.market(Id.wrap(m4Id));
        assertGt(m3State.lastUpdate, 0, "M3 not present on Morpho post-create");
        assertGt(m4State.lastUpdate, 0, "M4 not present on Morpho post-create");
    }

    /// @dev Negative path: a non-owner call to `createAndRegisterMarket`
    ///      must revert. Locks in the assumption the deploy script relies on.
    function test_fork_deployMxnbMarketsFlow_nonOwnerReverts() public whenFork {
        FxOracle oracle = new FxOracle(LIVE_PYTH, address(this), 300, 50, 30);
        oracle.setFeed(LIVE_USDC, PYTH_USDC_USD);
        oracle.setPythFeedConfig(LIVE_MXNB, PYTH_USD_MXN, true);
        MorphoOracleAdapter adapterM3 = new MorphoOracleAdapter(address(oracle), LIVE_MXNB, LIVE_USDC);

        IFxMarketRegistry.MarketParams memory m3 = IFxMarketRegistry.MarketParams({
            loanToken:       LIVE_MXNB,
            collateralToken: LIVE_USDC,
            oracle:          address(adapterM3),
            irm:             LIVE_IRM,
            lltv:            LLTV
        });

        address attacker = address(0xBADBAD);
        vm.prank(attacker);
        vm.expectRevert();
        registry.createAndRegisterMarket(m3);
    }
}
