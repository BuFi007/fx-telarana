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

/// @notice Fork test for `DeployArcAudfMarkets.s.sol`. Pins live Arc
///         testnet contract addresses (USDC, AUDF, Pyth, IRM,
///         FxMarketRegistry, Morpho Blue, the deployer EOA) and asserts:
///
///           1. The deployer is still the registry's `owner()`.
///           2. The IRM + 0.86 LLTV are enabled on the Arc Morpho.
///           3. AUDF on Arc has 6 decimals (matches the adapter scaling math).
///           4. The script's flow — fresh FxOracle, two MorphoOracleAdapters,
///              two `createAndRegisterMarket` calls — lands two new market
///              IDs in the registry and they match `MarketParamsLib.id()`.
///           5. M1 + M2 (the existing EURC/USDC pair) are NOT disturbed.
///
/// Gated by `ARC_RPC_URL`. Default `forge test` skips silently when unset
/// so the regular test path stays fast.
contract ArcAudfMarketForkTest is Test {
    using MarketParamsLib for MorphoMarketParams;

    // ---- live Arc Testnet addresses (deployments/arc-testnet.json + Forte) ----
    address constant LIVE_REGISTRY = 0x813232259c9b922e7571F15220617C80581f1464;
    address constant LIVE_MORPHO   = 0x3c9b95C6E7B23f094f066733E7797C8680760830;
    address constant LIVE_IRM      = 0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1;
    address constant LIVE_PYTH     = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address constant LIVE_USDC     = 0x3600000000000000000000000000000000000000;
    address constant LIVE_AUDF     = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address constant LIVE_DEPLOYER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    // Existing market IDs from deployments/arc-testnet.json.
    bytes32 constant LIVE_M1_ID = 0xf6fac2b9b801a7ae3deeccfa95a7f1e768b4873a22f0def0d93f7f0172cc2da2;
    bytes32 constant LIVE_M2_ID = 0x9e187a5f252de56b9ffe35f72cdc4137568f9d51698560751cdaff3df60cb5d3;

    // Pyth feed ids (Pyth's published catalog).
    bytes32 constant PYTH_USDC_USD =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_AUD_USD =
        0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80;

    uint256 constant LLTV = 0.86e18;

    ILegacyFxMarketRegistry internal registry;
    IMorpho internal morpho;

    bool internal forkActive;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_RPC_URL", string(""));
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
                        PIN: live Arc preconditions
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

    function test_fork_pin_audfHas6Decimals() public whenFork {
        // Forte's AUDF is 6-decimal (matches USDC scale). The adapter's
        // SCALE_FACTOR math assumes 36 + loanDec - collatDec; a surprise here
        // would crater the adapter price() result.
        assertEq(IERC20Decimals(LIVE_AUDF).decimals(), 6, "AUDF decimals != 6");
    }

    function test_fork_pin_m1AndM2StillRegistered() public whenFork {
        Market memory m1 = morpho.market(Id.wrap(LIVE_M1_ID));
        Market memory m2 = morpho.market(Id.wrap(LIVE_M2_ID));
        assertGt(m1.lastUpdate, 0, "M1 (EURC/USDC) missing from live Morpho");
        assertGt(m2.lastUpdate, 0, "M2 (USDC/EURC) missing from live Morpho");
    }

    /*//////////////////////////////////////////////////////////////
                FLOW: end-to-end audf-market provisioning
    //////////////////////////////////////////////////////////////*/

    function test_fork_deployAudfMarketsFlow_e2e() public whenFork {
        // 1) Fresh oracle wired for USDC + AUDF.
        FxOracle oracle = new FxOracle(LIVE_PYTH, address(this), 300, 50, 30);
        oracle.setFeed(LIVE_USDC, PYTH_USDC_USD);
        oracle.setPythFeedConfig(LIVE_AUDF, PYTH_AUD_USD, false /* not inverted */);

        // 2) Two adapters.
        MorphoOracleAdapter adapterM3 = new MorphoOracleAdapter(address(oracle), LIVE_AUDF, LIVE_USDC);
        MorphoOracleAdapter adapterM4 = new MorphoOracleAdapter(address(oracle), LIVE_USDC, LIVE_AUDF);

        // Adapter SCALE_FACTOR sanity: both tokens at 6 decimals → 1e36.
        assertEq(adapterM3.SCALE_FACTOR(), 1e36, "M3 adapter SCALE_FACTOR != 1e36");
        assertEq(adapterM4.SCALE_FACTOR(), 1e36, "M4 adapter SCALE_FACTOR != 1e36");

        // 3) Call createAndRegisterMarket twice as the deployer (=registry.owner()).
        IFxMarketRegistry.MarketParams memory m3 = IFxMarketRegistry.MarketParams({
            loanToken:       LIVE_AUDF,
            collateralToken: LIVE_USDC,
            oracle:          address(adapterM3),
            irm:             LIVE_IRM,
            lltv:            LLTV
        });
        IFxMarketRegistry.MarketParams memory m4 = IFxMarketRegistry.MarketParams({
            loanToken:       LIVE_USDC,
            collateralToken: LIVE_AUDF,
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

        // Cross-check against Morpho's marketId computation.
        bytes32 m3Expected = Id.unwrap(MorphoMarketParams({
            loanToken:       LIVE_AUDF,
            collateralToken: LIVE_USDC,
            oracle:          address(adapterM3),
            irm:             LIVE_IRM,
            lltv:            LLTV
        }).id());
        bytes32 m4Expected = Id.unwrap(MorphoMarketParams({
            loanToken:       LIVE_USDC,
            collateralToken: LIVE_AUDF,
            oracle:          address(adapterM4),
            irm:             LIVE_IRM,
            lltv:            LLTV
        }).id());
        assertEq(m3Id, m3Expected, "M3 id != Morpho.id()");
        assertEq(m4Id, m4Expected, "M4 id != Morpho.id()");

        // Must not collide with the live M1/M2.
        assertTrue(m3Id != LIVE_M1_ID && m3Id != LIVE_M2_ID, "M3 collides with M1/M2");
        assertTrue(m4Id != LIVE_M1_ID && m4Id != LIVE_M2_ID, "M4 collides with M1/M2");

        // Markets must now exist on Morpho.
        Market memory m3State = morpho.market(Id.wrap(m3Id));
        Market memory m4State = morpho.market(Id.wrap(m4Id));
        assertGt(m3State.lastUpdate, 0, "M3 not present on Morpho post-create");
        assertGt(m4State.lastUpdate, 0, "M4 not present on Morpho post-create");
    }

    function test_fork_deployAudfMarketsFlow_nonOwnerReverts() public whenFork {
        FxOracle oracle = new FxOracle(LIVE_PYTH, address(this), 300, 50, 30);
        oracle.setFeed(LIVE_USDC, PYTH_USDC_USD);
        oracle.setPythFeedConfig(LIVE_AUDF, PYTH_AUD_USD, false);
        MorphoOracleAdapter adapterM3 = new MorphoOracleAdapter(address(oracle), LIVE_AUDF, LIVE_USDC);

        IFxMarketRegistry.MarketParams memory m3 = IFxMarketRegistry.MarketParams({
            loanToken:       LIVE_AUDF,
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
