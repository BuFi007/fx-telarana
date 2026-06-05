// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {FxReserveYieldRouter} from "../../src/vault/FxReserveYieldRouter.sol";
import {IUsycTeller} from "../../src/vault/interfaces/IUsycTeller.sol";
import {MockUsycTeller} from "./FxReserveYieldRouter.t.sol";

/// @dev Borrow-free Morpho stand-in (mirrors SharedFxVault.t.sol's MockMorpho) + a `pokeInterest`
///      helper to simulate supply-side yield. Works for ANY loanToken (USDC-loan or FX-loan markets).
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

    /// @dev Simulate accrued supply interest: bump market assets (shares unchanged ⇒ assets/share up).
    ///      Caller must also fund the mock with the extra loanToken so withdrawals are payable.
    function pokeInterest(MarketParams memory m, uint256 addAssets) external {
        _market[m.id()].totalSupplyAssets += uint128(addAssets);
    }

    function market(Id id) external view returns (Market memory) {
        return _market[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _pos[id][user];
    }
}

contract FxReserveYieldRouterP2Test is Test {
    FxReserveYieldRouter router;
    MockERC20 usdc;
    MockERC20 usyc;
    MockERC20 eurc;
    MockUsycTeller teller;
    MockMorpho morpho;

    address admin = address(this);
    address timelock = makeAddr("timelock");
    address treasury = makeAddr("treasury");

    uint256 constant LOW = 100e6;
    uint256 constant HIGH = 500e6;

    MarketParams usdcMkt;
    MarketParams eurcMkt;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        usyc = new MockERC20("USYC", "USYC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        teller = new MockUsycTeller(usdc, usyc);
        morpho = new MockMorpho();

        FxReserveYieldRouter impl = new FxReserveYieldRouter();
        bytes memory initData = abi.encodeCall(
            FxReserveYieldRouter.initialize,
            (IERC20(address(usdc)), IERC20(address(usyc)), IUsycTeller(address(teller)), admin, timelock, LOW, HIGH)
        );
        router = FxReserveYieldRouter(address(new ERC1967Proxy(address(impl), initData)));
        router.grantRole(router.FUNDER_ROLE(), admin);
        router.grantRole(router.KEEPER_ROLE(), admin);

        usdcMkt = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(eurc),
            oracle: address(0xBEEF),
            irm: address(0xCAFE),
            lltv: 0.86e18
        });
        eurcMkt = MarketParams({
            loanToken: address(eurc),
            collateralToken: address(usdc),
            oracle: address(0xBEEF),
            irm: address(0xCAFE),
            lltv: 0.86e18
        });

        router.setMorpho(IMorpho(address(morpho)));
    }

    /*//////////////////////////////////////////////////////////////
                       USDC → MORPHO USDC-LOAN SINK
    //////////////////////////////////////////////////////////////*/

    function test_p2_usdc_enableRequiresMorphoSet() public {
        // fresh router with no morpho wired
        FxReserveYieldRouter impl = new FxReserveYieldRouter();
        bytes memory initData = abi.encodeCall(
            FxReserveYieldRouter.initialize,
            (IERC20(address(usdc)), IERC20(address(usyc)), IUsycTeller(address(teller)), admin, timelock, LOW, HIGH)
        );
        FxReserveYieldRouter r2 = FxReserveYieldRouter(address(new ERC1967Proxy(address(impl), initData)));
        vm.expectRevert(FxReserveYieldRouter.MorphoNotSet.selector);
        r2.setUsdcMorphoMarket(usdcMkt, true, 4_000);
    }

    function test_p2_usdc_marketRejectsWrongLoanToken() public {
        vm.expectRevert(FxReserveYieldRouter.MarketLoanTokenMismatch.selector);
        router.setUsdcMorphoMarket(eurcMkt, true, 4_000); // loanToken == eurc, not usdc
    }

    function test_p2_usdc_splitsDeployBetweenMorphoAndUsyc() public {
        router.setUsdcMorphoMarket(usdcMkt, true, 4_000); // 40% → Morpho
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance(); // deployable = 1000 - 500 = 500 → 200 Morpho, 300 USYC

        assertEq(router.liquidUsdc(), HIGH, "buffer at high-water");
        assertApproxEqAbs(router.usdcMorphoAssets(), 200e6, 1, "40% to Morpho");
        assertApproxEqAbs(router.usycValueUsdc(), 300e6, 2, "60% to USYC");
        assertApproxEqAbs(router.yieldAssets(), 1_000e6, 2, "total value preserved across both sinks");
    }

    function test_p2_usdc_morphoYieldRaisesNav() public {
        router.setUsdcMorphoMarket(usdcMkt, true, 10_000); // all to Morpho
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance(); // 500 → Morpho
        assertApproxEqAbs(router.accruedYieldUsdc(), 0, 2, "no yield yet");

        // simulate +25 USDC supply interest; fund the mock to back the larger withdrawal
        morpho.pokeInterest(usdcMkt, 25e6);
        usdc.mint(address(morpho), 25e6);

        assertApproxEqAbs(router.usdcMorphoAssets(), 525e6, 2, "Morpho NAV grew with interest");
        assertApproxEqAbs(router.accruedYieldUsdc(), 25e6, 2, "yield surfaced in NAV");
    }

    function test_p2_usdc_refillPullsMorphoFirstThenUsyc() public {
        router.setUsdcMorphoMarket(usdcMkt, true, 4_000);
        _fund(FxReserveYieldRouter.Tier.PROTOCOL, 1_000e6);
        router.rebalance(); // liquid 500, Morpho 200, USYC 300

        router.setWaterMarks(900e6, 1_000e6); // need 400 to refill
        usdc.mint(address(teller), 10e6); // dust headroom for USYC ceil rounding
        router.rebalance(); // pull Morpho 200 (all) then USYC 200

        assertApproxEqAbs(router.liquidUsdc(), 900e6, 2, "buffer refilled to low-water");
        assertApproxEqAbs(router.usdcMorphoAssets(), 0, 1, "Morpho drained first");
        assertApproxEqAbs(router.usycValueUsdc(), 100e6, 2, "USYC covered the remainder");
    }

    /*//////////////////////////////////////////////////////////////
                       FX → MORPHO FX-LOAN SINK
    //////////////////////////////////////////////////////////////*/

    function test_p2_fx_addMarketRejectsWrongLoanToken() public {
        vm.expectRevert(FxReserveYieldRouter.MarketLoanTokenMismatch.selector);
        router.addFxMarket(address(eurc), usdcMkt, 100e6, 200e6); // usdcMkt.loanToken != eurc
    }

    function test_p2_fx_depositAndRebalanceSupplies() public {
        router.addFxMarket(address(eurc), eurcMkt, 100e6, 200e6);
        _fundFx(1_000e6);
        router.rebalanceFx(address(eurc)); // liquid 1000 > 200 → supply 800

        assertEq(eurc.balanceOf(address(router)), 200e6, "FX buffer at high-water");
        assertApproxEqAbs(router.fxAssets(address(eurc)), 1_000e6, 1, "liquid + Morpho = inventory");
        assertEq(router.fxPrincipal(address(eurc)), 1_000e6, "principal tracked in native EURC");
    }

    function test_p2_fx_yieldIsNativeAndHarvestable() public {
        router.addFxMarket(address(eurc), eurcMkt, 100e6, 200e6);
        _fundFx(1_000e6);
        router.rebalanceFx(address(eurc)); // 800 supplied

        // +50 EURC supply interest, fund the mock to pay it
        morpho.pokeInterest(eurcMkt, 50e6);
        eurc.mint(address(morpho), 50e6);

        assertApproxEqAbs(router.fxAssets(address(eurc)), 1_050e6, 2, "FX inventory grew in EURC terms");
        assertApproxEqAbs(router.fxAccruedYield(address(eurc)), 50e6, 2, "yield in native EURC");

        uint256 y = router.fxAccruedYield(address(eurc));
        router.harvestFxYield(address(eurc), treasury, y);
        assertEq(eurc.balanceOf(treasury), y, "treasury received EURC yield");
        assertEq(router.fxPrincipal(address(eurc)), 1_000e6, "FX principal intact");
    }

    function test_p2_fx_withdrawRedeemsFromMorpho() public {
        router.addFxMarket(address(eurc), eurcMkt, 100e6, 200e6);
        _fundFx(1_000e6);
        router.rebalanceFx(address(eurc)); // liquid 200, Morpho 800
        router.withdrawFx(address(eurc), 900e6, treasury); // pulls 700 from Morpho
        assertEq(eurc.balanceOf(treasury), 900e6, "principal returned from buffer + Morpho");
        assertEq(router.fxPrincipal(address(eurc)), 100e6, "principal debited");
    }

    function test_p2_fx_rebalanceRefillsBufferFromMorpho() public {
        router.addFxMarket(address(eurc), eurcMkt, 100e6, 200e6);
        _fundFx(1_000e6);
        router.rebalanceFx(address(eurc)); // liquid 200, Morpho 800
        router.setFxWaterMarks(address(eurc), 500e6, 600e6);
        router.rebalanceFx(address(eurc)); // liquid 200 < 500 → withdraw 300
        assertApproxEqAbs(eurc.balanceOf(address(router)), 500e6, 2, "FX buffer refilled");
    }

    function test_p2_fx_notManagedReverts() public {
        MockERC20 mxnb = new MockERC20("MXNB", "MXNB", 6);
        mxnb.mint(admin, 100e6);
        mxnb.approve(address(router), 100e6);
        vm.expectRevert(FxReserveYieldRouter.FxNotManaged.selector);
        router.depositFx(address(mxnb), 100e6);
    }

    function test_p2_fx_listTracksManagedTokens() public {
        router.addFxMarket(address(eurc), eurcMkt, 100e6, 200e6);
        address[] memory toks = router.fxTokens();
        assertEq(toks.length, 1);
        assertEq(toks[0], address(eurc));
    }

    /*//////////////////////////////////////////////////////////////
                       COMPLIANCE WALL — still intact
    //////////////////////////////////////////////////////////////*/

    function test_p2_compliance_retailStillForbidden() public {
        router.setUsdcMorphoMarket(usdcMkt, true, 5_000);
        vm.expectRevert(FxReserveYieldRouter.RetailForbidden.selector);
        router.depositFor(FxReserveYieldRouter.Tier.RETAIL, 1);
        assertEq(router.tierPrincipal(FxReserveYieldRouter.Tier.RETAIL), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/
    function _fund(FxReserveYieldRouter.Tier tier, uint256 amount) internal {
        usdc.mint(admin, amount);
        usdc.approve(address(router), amount);
        router.depositFor(tier, amount);
    }

    function _fundFx(uint256 amount) internal {
        eurc.mint(admin, amount);
        eurc.approve(address(router), amount);
        router.depositFx(address(eurc), amount);
    }
}
