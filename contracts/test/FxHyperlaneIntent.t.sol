// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FxHyperlaneHubReceiver} from "../src/hub/FxHyperlaneHubReceiver.sol";
import {FxSpokeIntentRouter} from "../src/spoke/FxSpokeIntentRouter.sol";
import {FxHyperlaneIntentLib} from "../src/libraries/FxHyperlaneIntentLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHyperlaneMailbox} from "./mocks/MockHyperlaneMailbox.sol";

contract MockFxMarketRegistry {
    using SafeERC20 for IERC20;

    bool public live = true;
    bytes32 public lastAction;
    address public lastLoanToken;
    address public lastCollateralToken;
    uint256 public lastAmount;
    address public lastOnBehalf;

    uint256 public supplyShares = 111;
    uint256 public repayShares = 222;
    uint256 public borrowShares = 333;
    mapping(address account => mapping(address delegate => bool allowed)) public borrowDelegateOf;

    function setLive(bool live_) external {
        live = live_;
    }

    function isPoolLive(address, address) external view returns (bool) {
        return live;
    }

    function supply(address loanToken, address collateralToken, uint256 assets, address onBehalf)
        external
        returns (uint256 sharesMinted)
    {
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), assets);
        _record("supply", loanToken, collateralToken, assets, onBehalf);
        return supplyShares;
    }

    function supplyCollateral(address loanToken, address collateralToken, uint256 collateral, address onBehalf)
        external
    {
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateral);
        _record("supplyCollateral", loanToken, collateralToken, collateral, onBehalf);
    }

    function repay(address loanToken, address collateralToken, uint256 assets, address onBehalf)
        external
        returns (uint256 sharesBurned)
    {
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), assets);
        _record("repay", loanToken, collateralToken, assets, onBehalf);
        return repayShares;
    }

    function setBorrowDelegate(address delegate, bool allowed) external {
        borrowDelegateOf[msg.sender][delegate] = allowed;
    }

    function borrowDelegated(
        address loanToken,
        address collateralToken,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external returns (uint256 borrowedShares) {
        require(borrowDelegateOf[onBehalf][msg.sender], "not delegate");
        MockERC20(loanToken).mint(receiver, assets);
        _record("borrowDelegated", loanToken, collateralToken, assets, onBehalf);
        return borrowShares;
    }

    function _record(string memory action, address loanToken, address collateralToken, uint256 amount, address onBehalf)
        internal
    {
        lastAction = keccak256(bytes(action));
        lastLoanToken = loanToken;
        lastCollateralToken = collateralToken;
        lastAmount = amount;
        lastOnBehalf = onBehalf;
    }
}

contract FxHyperlaneIntentTest is Test {
    MockHyperlaneMailbox internal mailbox;
    MockFxMarketRegistry internal registry;
    FxHyperlaneHubReceiver internal hub;
    FxSpokeIntentRouter internal router;
    MockERC20 internal usdc;
    MockERC20 internal jpyc;

    address internal admin = address(this);
    address internal alice = address(0xA11CE);
    address internal route = address(0xA0DF);

    uint32 internal constant SPOKE_DOMAIN = 43_113;
    uint32 internal constant HUB_DOMAIN = 43_114;

    function setUp() public {
        mailbox = new MockHyperlaneMailbox();
        registry = new MockFxMarketRegistry();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        jpyc = new MockERC20("JPYC", "JPYC", 18);
        hub = new FxHyperlaneHubReceiver(address(mailbox), address(registry), admin);
        router = new FxSpokeIntentRouter(address(mailbox), SPOKE_DOMAIN, HUB_DOMAIN, _addressToBytes32(address(hub)));

        hub.setTrustedSpoke(SPOKE_DOMAIN, _addressToBytes32(address(router)), true);
        hub.setRouteAsset(SPOKE_DOMAIN, route, address(usdc), true);
        hub.setRouteAsset(SPOKE_DOMAIN, route, address(jpyc), true);
        vm.deal(alice, 10 ether);
    }

    function test_spokeDispatchesTypedIntentThroughMailbox() public {
        uint256 fee = router.quoteIntent(
            uint8(FxHyperlaneIntentLib.Action.SupplyCollateral),
            alice,
            address(usdc),
            1_000_000,
            address(jpyc),
            address(usdc),
            route
        );

        vm.prank(alice);
        (bytes32 intentId, bytes32 messageId) = router.sendIntent{value: fee}(
            uint8(FxHyperlaneIntentLib.Action.SupplyCollateral),
            alice,
            address(usdc),
            1_000_000,
            address(jpyc),
            address(usdc),
            route
        );

        FxHyperlaneIntentLib.Intent memory intent = FxHyperlaneIntentLib.decode(mailbox.lastBody());

        assertEq(mailbox.lastDestinationDomain(), HUB_DOMAIN);
        assertEq(mailbox.lastRecipient(), _addressToBytes32(address(hub)));
        assertEq(mailbox.lastSender(), address(router));
        assertEq(mailbox.lastValue(), fee);
        assertEq(uint8(intent.action), uint8(FxHyperlaneIntentLib.Action.SupplyCollateral));
        assertEq(intent.beneficiary, alice);
        assertEq(intent.inputToken, address(usdc));
        assertEq(intent.inputAmount, 1_000_000);
        assertEq(intent.loanToken, address(jpyc));
        assertEq(intent.collateralToken, address(usdc));
        assertEq(intent.route, route);
        assertEq(intentId, FxHyperlaneIntentLib.intentId(SPOKE_DOMAIN, _addressToBytes32(address(router)), intent));
        assertTrue(messageId != bytes32(0));
    }

    function test_hubRejectsNonMailbox() public {
        bytes memory body = _body(
            FxHyperlaneIntentLib.Action.SupplyCollateral,
            alice,
            address(usdc),
            1_000_000,
            address(jpyc),
            address(usdc),
            route,
            keccak256("n1")
        );

        vm.expectRevert(abi.encodeWithSelector(FxHyperlaneHubReceiver.NotMailbox.selector, address(this)));
        hub.handle(SPOKE_DOMAIN, _addressToBytes32(address(router)), body);
    }

    function test_adminCanSetAppSpecificIsm() public {
        address ism = address(0x5151);

        vm.expectEmit(true, false, false, true);
        emit FxHyperlaneHubReceiver.InterchainSecurityModuleSet(ism);
        hub.setInterchainSecurityModule(ism);

        assertEq(address(hub.interchainSecurityModule()), ism);
    }

    function test_hubRejectsUntrustedSpoke() public {
        bytes memory body = _body(
            FxHyperlaneIntentLib.Action.SupplyCollateral,
            alice,
            address(usdc),
            1_000_000,
            address(jpyc),
            address(usdc),
            route,
            keccak256("n1")
        );

        bytes32 badSpoke = _addressToBytes32(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(FxHyperlaneHubReceiver.UntrustedSpoke.selector, SPOKE_DOMAIN, badSpoke));
        mailbox.deliver(address(hub), SPOKE_DOMAIN, badSpoke, body);
    }

    function test_hubAcceptsTrustedRouteAndStoresIntent() public {
        (bytes32 intentId, bytes memory body) = _dispatchSupplyCollateralIntent(1_000_000);

        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);

        assertEq(uint8(hub.intentState(intentId)), uint8(FxHyperlaneHubReceiver.IntentState.Accepted));
        FxHyperlaneIntentLib.Intent memory stored = hub.intent(intentId);
        assertEq(stored.beneficiary, alice);
        assertEq(stored.inputToken, address(usdc));

        (uint32 origin, bytes32 sender) = hub.intentRoute(intentId);
        assertEq(origin, SPOKE_DOMAIN);
        assertEq(sender, _addressToBytes32(address(router)));
    }

    function test_executeSupplyCollateralPullsFromBeneficiaryAndCallsRegistry() public {
        (bytes32 intentId, bytes memory body) = _dispatchSupplyCollateralIntent(2_000_000);
        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);

        usdc.mint(alice, 2_000_000);
        vm.prank(alice);
        usdc.approve(address(hub), 2_000_000);

        vm.prank(alice);
        hub.executeIntent(intentId);

        assertEq(uint8(hub.intentState(intentId)), uint8(FxHyperlaneHubReceiver.IntentState.Executed));
        assertEq(registry.lastAction(), keccak256("supplyCollateral"));
        assertEq(registry.lastLoanToken(), address(jpyc));
        assertEq(registry.lastCollateralToken(), address(usdc));
        assertEq(registry.lastAmount(), 2_000_000);
        assertEq(registry.lastOnBehalf(), alice);
        assertEq(usdc.balanceOf(address(registry)), 2_000_000);
        assertEq(usdc.balanceOf(address(hub)), 0);
        assertEq(usdc.allowance(address(hub), address(registry)), 0);
    }

    function test_executeBorrowIntentUsesRegistryDelegate() public {
        bytes memory body = _body(
            FxHyperlaneIntentLib.Action.Borrow,
            alice,
            address(0),
            10e18,
            address(jpyc),
            address(usdc),
            address(0),
            keccak256("borrow")
        );
        FxHyperlaneIntentLib.Intent memory intent = FxHyperlaneIntentLib.decode(body);
        bytes32 intentId = FxHyperlaneIntentLib.intentId(SPOKE_DOMAIN, _addressToBytes32(address(router)), intent);

        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);
        assertEq(uint8(hub.intentState(intentId)), uint8(FxHyperlaneHubReceiver.IntentState.Accepted));

        vm.prank(alice);
        registry.setBorrowDelegate(address(hub), true);

        vm.prank(alice);
        hub.executeIntent(intentId);

        assertEq(uint8(hub.intentState(intentId)), uint8(FxHyperlaneHubReceiver.IntentState.Executed));
        assertEq(registry.lastAction(), keccak256("borrowDelegated"));
        assertEq(registry.lastLoanToken(), address(jpyc));
        assertEq(registry.lastCollateralToken(), address(usdc));
        assertEq(registry.lastAmount(), 10e18);
        assertEq(registry.lastOnBehalf(), alice);
        assertEq(jpyc.balanceOf(alice), 10e18);
    }

    function test_borrowIntentRejectsZeroBorrowAmount() public {
        bytes memory body = _body(
            FxHyperlaneIntentLib.Action.Borrow,
            alice,
            address(0),
            0,
            address(jpyc),
            address(usdc),
            address(0),
            keccak256("borrow")
        );

        vm.expectRevert(FxHyperlaneHubReceiver.InvalidIntent.selector);
        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);
    }

    function test_executeRoutedIntentUsesWarpDeliveredBalance() public {
        (bytes32 intentId, bytes memory body) = _dispatchSupplyCollateralIntent(3_000_000);
        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);

        usdc.mint(address(hub), 3_000_000);

        vm.prank(route);
        hub.executeRoutedIntent(intentId);

        assertEq(uint8(hub.intentState(intentId)), uint8(FxHyperlaneHubReceiver.IntentState.Executed));
        assertEq(registry.lastAction(), keccak256("supplyCollateral"));
        assertEq(registry.lastLoanToken(), address(jpyc));
        assertEq(registry.lastCollateralToken(), address(usdc));
        assertEq(registry.lastAmount(), 3_000_000);
        assertEq(registry.lastOnBehalf(), alice);
        assertEq(usdc.balanceOf(address(registry)), 3_000_000);
        assertEq(usdc.balanceOf(address(hub)), 0);
    }

    function test_executeRoutedIntentRequiresRouteCaller() public {
        (bytes32 intentId, bytes memory body) = _dispatchSupplyCollateralIntent(3_000_000);
        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);
        usdc.mint(address(hub), 3_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                FxHyperlaneHubReceiver.RouteAssetNotAllowed.selector, SPOKE_DOMAIN, alice, address(usdc)
            )
        );
        vm.prank(alice);
        hub.executeRoutedIntent(intentId);
    }

    function test_replayNonceRejected() public {
        (, bytes memory body) = _dispatchSupplyCollateralIntent(1_000_000);

        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);
        FxHyperlaneIntentLib.Intent memory intent = FxHyperlaneIntentLib.decode(body);
        bytes32 intentId = FxHyperlaneIntentLib.intentId(SPOKE_DOMAIN, _addressToBytes32(address(router)), intent);
        vm.expectRevert(abi.encodeWithSelector(FxHyperlaneHubReceiver.DuplicateIntent.selector, intentId));
        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);
    }

    function test_routeAssetCanBeRemovedBeforeExecution() public {
        (bytes32 intentId, bytes memory body) = _dispatchSupplyCollateralIntent(1_000_000);
        mailbox.deliver(address(hub), SPOKE_DOMAIN, _addressToBytes32(address(router)), body);

        hub.setRouteAsset(SPOKE_DOMAIN, route, address(usdc), false);

        usdc.mint(alice, 1_000_000);
        vm.prank(alice);
        usdc.approve(address(hub), 1_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                FxHyperlaneHubReceiver.RouteAssetNotAllowed.selector, SPOKE_DOMAIN, route, address(usdc)
            )
        );
        vm.prank(alice);
        hub.executeIntent(intentId);
    }

    function _dispatchSupplyCollateralIntent(uint256 amount) internal returns (bytes32 intentId, bytes memory body) {
        uint256 fee = router.quoteIntent(
            uint8(FxHyperlaneIntentLib.Action.SupplyCollateral),
            alice,
            address(usdc),
            amount,
            address(jpyc),
            address(usdc),
            route
        );
        vm.prank(alice);
        (intentId,) = router.sendIntent{value: fee}(
            uint8(FxHyperlaneIntentLib.Action.SupplyCollateral),
            alice,
            address(usdc),
            amount,
            address(jpyc),
            address(usdc),
            route
        );
        body = mailbox.lastBody();
    }

    function _body(
        FxHyperlaneIntentLib.Action action,
        address beneficiary,
        address inputToken,
        uint256 inputAmount,
        address loanToken,
        address collateralToken,
        address route_,
        bytes32 nonce
    ) internal pure returns (bytes memory) {
        return FxHyperlaneIntentLib.encode(
            FxHyperlaneIntentLib.Intent({
                version: FxHyperlaneIntentLib.VERSION,
                action: action,
                nonce: nonce,
                beneficiary: beneficiary,
                inputToken: inputToken,
                inputAmount: inputAmount,
                loanToken: loanToken,
                collateralToken: collateralToken,
                route: route_
            })
        );
    }

    function _addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
