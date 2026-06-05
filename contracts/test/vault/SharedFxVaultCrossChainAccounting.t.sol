// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorpho, MockOracle} from "./SharedFxVault.t.sol";
import {MockUsycTeller} from "./FxReserveYieldRouter.t.sol";
import {FxUsycAdapter} from "../../src/vault/FxUsycAdapter.sol";
import {IUsycTeller} from "../../src/vault/interfaces/IUsycTeller.sol";
import {SharedFxVault} from "../../src/vault/SharedFxVault.sol";

contract GatewayTransitHandler {
    SharedFxVault public immutable vault;

    constructor(SharedFxVault vault_) {
        vault = vault_;
    }

    function recordBurn(uint96 raw) external {
        uint256 hot = vault.seniorUsdcHot();
        if (hot == 0) return;
        uint256 assets = uint256(raw) % (hot + 1);
        if (assets == 0) return;
        vault.recordGatewayBurn(assets);
    }

    function clearMint(uint96 raw) external {
        uint256 inTransit = vault.gatewayInTransitUsdc();
        if (inTransit == 0) return;
        uint256 assets = uint256(raw) % (inTransit + 1);
        if (assets == 0) return;
        vault.clearGatewayMint(assets);
    }
}

contract SharedFxVaultCrossChainAccountingTest is StdInvariant, Test {
    SharedFxVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockERC20 internal usyc;
    MockMorpho internal morpho;
    MockOracle internal oracle;
    MockUsycTeller internal teller;
    GatewayTransitHandler internal handler;

    address internal admin = address(this);
    address internal timelock = makeAddr("timelock");
    address internal poolManager = makeAddr("poolManager");
    address internal alice = makeAddr("alice");

    uint256 internal initialAssets;
    uint256 internal aliceShares;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        usyc = new MockERC20("USYC", "USYC", 6);
        morpho = new MockMorpho();
        oracle = new MockOracle();
        teller = new MockUsycTeller(usdc, usyc);

        vault = _deployVault();
        vault.grantRole(vault.KEEPER_ROLE(), admin);

        _seniorDeposit(alice, 1_000e6);
        initialAssets = vault.totalAssets();
        aliceShares = vault.balanceOf(alice);

        handler = new GatewayTransitHandler(vault);
        vault.grantRole(vault.GATEWAY_ACCOUNTANT_ROLE(), address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = GatewayTransitHandler.recordBurn.selector;
        selectors[1] = GatewayTransitHandler.clearMint.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function test_gatewayTransitBucketPreservesTotalAssetsAndSharePrice() public {
        vault.grantRole(vault.GATEWAY_ACCOUNTANT_ROLE(), admin);

        uint256 assetsBefore = vault.totalAssets();
        uint256 shareValueBefore = vault.convertToAssets(aliceShares);

        vault.recordGatewayBurn(400e6);
        assertEq(vault.seniorUsdcHot(), 600e6, "hot leg debited");
        assertEq(vault.gatewayInTransitUsdc(), 400e6, "in-flight leg credited");
        assertEq(vault.totalAssets(), assetsBefore, "NAV unchanged during in-flight window");
        assertEq(vault.convertToAssets(aliceShares), shareValueBefore, "share price unchanged");

        vault.clearGatewayMint(400e6);
        assertEq(vault.seniorUsdcHot(), 1_000e6, "hot leg restored");
        assertEq(vault.gatewayInTransitUsdc(), 0, "in-flight leg cleared");
        assertEq(vault.totalAssets(), assetsBefore, "NAV unchanged after clear");
        assertEq(vault.convertToAssets(aliceShares), shareValueBefore, "share price still unchanged");
    }

    function test_usycAdapterMarksNavWithTellerPreviewRedeem() public {
        FxUsycAdapter adapter = new FxUsycAdapter(
            IERC20(address(usdc)), IERC20(address(usyc)), IUsycTeller(address(teller)), admin, address(vault)
        );
        vault.setYieldAdapter(address(adapter));

        uint256 assetsBefore = vault.totalAssets();
        vault.deploySeniorToYield(400e6);

        assertEq(vault.seniorUsdcHot(), 600e6, "hot senior moved to adapter");
        assertGt(vault.yieldAdapterAssets(), 0, "adapter opened USYC position");
        assertApproxEqAbs(vault.totalAssets(), assetsBefore, 2, "USYC round-trip NAV is stable except rounding");

        uint256 priceAfterYield = (teller.priceE6() * 105) / 100;
        teller.setPrice(priceAfterYield);
        usdc.mint(address(teller), 50e6);
        assertGt(vault.totalAssets(), assetsBefore, "Teller previewRedeem yield flows into NAV");

        uint256 hotBefore = vault.seniorUsdcHot();
        vault.redeemSeniorFromYield(50e6);
        assertGt(vault.seniorUsdcHot(), hotBefore, "redeem restores hot senior USDC");
    }

    function invariant_gatewayTransitDoesNotMoveSharePrice() public view {
        assertEq(vault.totalAssets(), initialAssets);
        assertEq(vault.convertToAssets(aliceShares), initialAssets);
        assertEq(vault.seniorUsdcHot() + vault.gatewayInTransitUsdc(), initialAssets);
    }

    function _deployVault() internal returns (SharedFxVault deployed) {
        SharedFxVault impl = new SharedFxVault();
        MarketParams memory market = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(eurc),
            oracle: address(0xBEEF),
            irm: address(0xCAFE),
            lltv: 0.86e18
        });
        bytes memory initData = abi.encodeCall(
            SharedFxVault.initialize,
            (IERC20(address(usdc)), admin, timelock, poolManager, address(oracle), IMorpho(address(morpho)), market)
        );
        deployed = SharedFxVault(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _seniorDeposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }
}
