// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IBufiKycPass} from "../src/interfaces/IBufiKycPass.sol";
import {IFxGhostWithdrawalVerifier} from "../src/interfaces/IFxGhostWithdrawalVerifier.sol";
import {FxGhostCommitmentRegistry} from "../src/ghost/FxGhostCommitmentRegistry.sol";
import {FxGhostKycHook} from "../src/ghost/FxGhostKycHook.sol";
import {FxGhostSpokeRouter} from "../src/ghost/FxGhostSpokeRouter.sol";
import {FxGhostWithdrawalRouter} from "../src/ghost/FxGhostWithdrawalRouter.sol";
import {FxSpoke} from "../src/spoke/FxSpoke.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMessageTransmitter} from "./mocks/MockMessageTransmitter.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";

contract MockBufiKycPass is IBufiKycPass {
    enum Status {
        None,
        Valid,
        Expired,
        Revoked
    }

    mapping(address account => uint8 level) public levels;
    mapping(address account => Status status) public statuses;

    function setPass(address account, Status status, uint8 level) external {
        statuses[account] = status;
        levels[account] = level;
    }

    function hasValidPass(address account) external view returns (bool valid) {
        return statuses[account] == Status.Valid;
    }

    function passLevel(address account) external view returns (uint8 level) {
        return levels[account];
    }
}

contract MockGhostWithdrawalVerifier is IFxGhostWithdrawalVerifier {
    bool public valid = true;

    function setValid(bool valid_) external {
        valid = valid_;
    }

    function verifyGhostWithdrawal(
        bytes32 root,
        bytes32 nullifierHash,
        bytes32 routeId,
        address passAccount,
        address token,
        uint256 amount,
        address recipient,
        bytes32 metadataRef,
        bytes calldata proof
    ) external view override returns (bool) {
        root;
        nullifierHash;
        routeId;
        passAccount;
        token;
        amount;
        recipient;
        metadataRef;
        proof;
        return valid;
    }
}

contract FxGhostModeTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockERC20 internal randomToken;
    MockMessageTransmitter internal mt;
    MockTokenMessenger internal messenger;
    FxSpoke internal spoke;
    MockBufiKycPass internal pass;
    FxGhostCommitmentRegistry internal registry;
    FxGhostSpokeRouter internal router;
    MockGhostWithdrawalVerifier internal withdrawalVerifier;
    FxGhostWithdrawalRouter internal withdrawalRouter;
    FxGhostKycHook internal hook;

    address internal admin = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal beneficiary = address(0xBEEF);
    address internal hubReceiver = address(0xABC);
    address internal poolManager = address(0x9001);
    address internal trustedSwapRouter = address(0xA0DF);
    address internal untrustedSwapRouter = address(0xBAD);

    bytes32 internal constant ROUTE_ID = keccak256("ghost-cctp-usdc");
    bytes32 internal constant KYB_ROUTE_ID = keccak256("ghost-cctp-usdc-kyb");
    bytes32 internal constant COMMITMENT = keccak256("commitment-1");
    bytes32 internal constant ROOT = keccak256("root-1");
    uint32 internal constant ARC_DOMAIN = 26;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        eurc = new MockERC20("EURC", "EURC", 6);
        randomToken = new MockERC20("DAI", "DAI", 18);

        mt = new MockMessageTransmitter(usdc, 0);
        messenger = new MockTokenMessenger(address(mt));
        spoke = new FxSpoke(address(messenger), address(usdc), hubReceiver, ARC_DOMAIN);
        spoke.setCircleTokenAllowed(address(eurc), true);

        pass = new MockBufiKycPass();
        registry = new FxGhostCommitmentRegistry(admin);
        router = new FxGhostSpokeRouter(address(spoke), address(pass), address(registry), admin);
        registry.setCommitmentRecorder(address(router), true);
        registry.setNullifierConsumer(admin, true);

        router.setGhostRoute(ROUTE_ID, address(usdc), 1, true, keccak256("ghost-usdc-route"));
        router.setGhostRoute(KYB_ROUTE_ID, address(usdc), 2, true, keccak256("ghost-usdc-kyb-route"));

        withdrawalVerifier = new MockGhostWithdrawalVerifier();
        withdrawalRouter =
            new FxGhostWithdrawalRouter(address(pass), address(withdrawalVerifier), address(registry), admin);
        registry.setNullifierConsumer(address(withdrawalRouter), true);
        withdrawalRouter.setWithdrawalRoute(ROUTE_ID, address(usdc), 1, true, keccak256("ghost-usdc-withdraw"));
        withdrawalRouter.setWithdrawalRoute(KYB_ROUTE_ID, address(usdc), 2, true, keccak256("ghost-usdc-kyb-withdraw"));

        hook = new FxGhostKycHook(poolManager, address(pass), admin);
        hook.setTrustedRouter(trustedSwapRouter, true);

        usdc.mint(alice, 10_000_000);
        usdc.mint(address(withdrawalRouter), 10_000_000);
        eurc.mint(alice, 10_000_000);
        randomToken.mint(alice, 10_000_000);
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        eurc.approve(address(router), type(uint256).max);
        randomToken.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_ghostSpokeEnter_allowsKycLevelOneAndUsesExplicitBeneficiary() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.prank(alice);
        bytes32 messageNonce = router.enterHubGhost(ROUTE_ID, COMMITMENT, 1_000_000, beneficiary, hex"deadbeef");

        assertTrue(messageNonce != bytes32(0));
        assertEq(usdc.balanceOf(address(messenger)), 1_000_000);
        assertEq(messenger.callCount(), 1);

        (
            uint256 amount,
            uint32 destDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destCaller,,,
            bytes memory hookData,
            bool withHook
        ) = messenger.last();

        assertEq(amount, 1_000_000);
        assertEq(destDomain, ARC_DOMAIN);
        assertEq(mintRecipient, bytes32(uint256(uint160(hubReceiver))));
        assertEq(destCaller, bytes32(uint256(uint160(hubReceiver))));
        assertEq(burnToken, address(usdc));
        assertTrue(withHook);
        assertEq(keccak256(hookData), keccak256(abi.encode(beneficiary, hex"deadbeef")));

        FxGhostCommitmentRegistry.CommitmentRecord memory record = registry.commitment(COMMITMENT);
        assertEq(record.routeId, ROUTE_ID);
        assertEq(record.account, alice);
        assertEq(record.beneficiary, beneficiary);
        assertEq(record.token, address(usdc));
        assertEq(record.amount, 1_000_000);
    }

    function test_ghostSpokeEnter_allowsKybLevelTwoRoute() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 2);

        vm.prank(alice);
        router.enterHubGhost(KYB_ROUTE_ID, keccak256("kyb-commitment"), 1_000_000, beneficiary, "");

        assertEq(messenger.callCount(), 1);
    }

    function test_ghostSpokeEnter_revertsWhenPassMissingExpiredOrRevoked() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostSpokeRouter.InvalidPass.selector, alice, 0, 1));
        router.enterHubGhost(ROUTE_ID, keccak256("missing"), 1_000_000, beneficiary, "");

        pass.setPass(alice, MockBufiKycPass.Status.Expired, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostSpokeRouter.InvalidPass.selector, alice, 1, 1));
        router.enterHubGhost(ROUTE_ID, keccak256("expired"), 1_000_000, beneficiary, "");

        pass.setPass(alice, MockBufiKycPass.Status.Revoked, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostSpokeRouter.InvalidPass.selector, alice, 1, 1));
        router.enterHubGhost(ROUTE_ID, keccak256("revoked"), 1_000_000, beneficiary, "");
    }

    function test_ghostSpokeEnter_revertsWhenPassLevelBelowRouteMinimum() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostSpokeRouter.InvalidPass.selector, alice, 1, 2));
        router.enterHubGhost(KYB_ROUTE_ID, COMMITMENT, 1_000_000, beneficiary, "");
    }

    function test_ghostSpokeEnter_doesNotUseTxOriginForPass() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.prank(alice, bob);
        router.enterHubGhost(ROUTE_ID, COMMITMENT, 1_000_000, beneficiary, "");
        assertEq(messenger.callCount(), 1);

        bytes32 secondCommitment = keccak256("tx-origin-only");
        pass.setPass(bob, MockBufiKycPass.Status.Valid, 1);
        vm.prank(address(0xCAFE), bob);
        vm.expectRevert(abi.encodeWithSelector(FxGhostSpokeRouter.InvalidPass.selector, address(0xCAFE), 0, 1));
        router.enterHubGhost(ROUTE_ID, secondCommitment, 1_000_000, beneficiary, "");
    }

    function test_ghostSpokeEnter_rejectsUnsupportedRoutesAndTokens() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostSpokeRouter.InvalidRoute.selector, bytes32("missing")));
        router.enterHubGhost(bytes32("missing"), COMMITMENT, 1_000_000, beneficiary, "");

        router.setGhostRoute(ROUTE_ID, address(usdc), 1, false, keccak256("disabled"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostSpokeRouter.RouteDisabled.selector, ROUTE_ID));
        router.enterHubGhost(ROUTE_ID, COMMITMENT, 1_000_000, beneficiary, "");

        vm.expectRevert(
            abi.encodeWithSelector(FxGhostSpokeRouter.UnsupportedRouteToken.selector, ROUTE_ID, address(randomToken))
        );
        router.setGhostRoute(ROUTE_ID, address(randomToken), 1, true, keccak256("random-token"));
    }

    function test_registry_rejectsDuplicateCommitmentAndNullifier() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.prank(alice);
        router.enterHubGhost(ROUTE_ID, COMMITMENT, 1_000_000, beneficiary, "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostCommitmentRegistry.DuplicateCommitment.selector, COMMITMENT));
        router.enterHubGhost(ROUTE_ID, COMMITMENT, 1_000_000, beneficiary, "");

        bytes32 nullifier = keccak256("nullifier-1");
        registry.consumeNullifier(nullifier);
        vm.expectRevert(abi.encodeWithSelector(FxGhostCommitmentRegistry.DuplicateNullifier.selector, nullifier));
        registry.consumeNullifier(nullifier);
    }

    function test_registry_rejectsZeroCommitmentAndNullifier() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.prank(alice);
        vm.expectRevert(FxGhostSpokeRouter.ZeroCommitment.selector);
        router.enterHubGhost(ROUTE_ID, bytes32(0), 1_000_000, beneficiary, "");

        vm.expectRevert(FxGhostCommitmentRegistry.ZeroNullifier.selector);
        registry.consumeNullifier(bytes32(0));
    }

    function test_registry_adminOnlyRootAndRecorderConfig() public {
        vm.prank(alice);
        vm.expectRevert(FxGhostCommitmentRegistry.NotOwner.selector);
        registry.setRoot(ROOT, true, uint64(block.timestamp + 1 days), keccak256("root-metadata"));

        registry.setRoot(ROOT, true, uint64(block.timestamp + 1 days), keccak256("root-metadata"));
        (bool active, uint64 validUntil,) = registry.roots(ROOT);
        assertTrue(active);
        assertEq(validUntil, uint64(block.timestamp + 1 days));

        vm.prank(alice);
        vm.expectRevert(FxGhostCommitmentRegistry.NotOwner.selector);
        registry.setCommitmentRecorder(alice, true);
    }

    function test_registry_rejectsUnauthorizedRecorderAndConsumer() public {
        vm.expectRevert(
            abi.encodeWithSelector(FxGhostCommitmentRegistry.UnauthorizedCommitmentRecorder.selector, alice)
        );
        vm.prank(alice);
        registry.registerCommitment(COMMITMENT, ROUTE_ID, alice, beneficiary, address(usdc), 1_000_000, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(FxGhostCommitmentRegistry.UnauthorizedNullifierConsumer.selector, alice));
        vm.prank(alice);
        registry.consumeNullifier(keccak256("nullifier"));
    }

    function test_withdrawalRouter_verifiesConsumesAndPaysRecipient() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);
        registry.setRoot(ROOT, true, uint64(block.timestamp + 1 days), keccak256("root-metadata"));

        bytes32 nullifier = keccak256("withdraw-nullifier");
        uint256 recipientBefore = usdc.balanceOf(beneficiary);

        vm.expectEmit(true, true, true, true);
        emit FxGhostWithdrawalRouter.GhostWithdrawalCompleted(
            nullifier, ROUTE_ID, beneficiary, address(usdc), 1_000_000, 1, ROOT, keccak256("proof-metadata")
        );
        withdrawalRouter.withdrawWithProof(
            ROUTE_ID, ROOT, nullifier, alice, beneficiary, 1_000_000, keccak256("proof-metadata"), hex"1234"
        );

        assertTrue(registry.nullifierConsumed(nullifier));
        assertEq(usdc.balanceOf(beneficiary), recipientBefore + 1_000_000);
    }

    function test_withdrawalRouter_rejectsDuplicateNullifier() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);
        registry.setRoot(ROOT, true, uint64(block.timestamp + 1 days), bytes32(0));
        bytes32 nullifier = keccak256("duplicate-withdraw-nullifier");

        withdrawalRouter.withdrawWithProof(ROUTE_ID, ROOT, nullifier, alice, beneficiary, 1_000_000, bytes32(0), "");

        vm.expectRevert(abi.encodeWithSelector(FxGhostCommitmentRegistry.DuplicateNullifier.selector, nullifier));
        withdrawalRouter.withdrawWithProof(ROUTE_ID, ROOT, nullifier, alice, beneficiary, 1_000_000, bytes32(0), "");
    }

    function test_withdrawalRouter_rejectsZeroInputs() public {
        vm.expectRevert(FxGhostWithdrawalRouter.ZeroRoot.selector);
        withdrawalRouter.withdrawWithProof(
            ROUTE_ID, bytes32(0), keccak256("nullifier"), alice, beneficiary, 1_000_000, bytes32(0), ""
        );

        vm.expectRevert(FxGhostWithdrawalRouter.ZeroNullifier.selector);
        withdrawalRouter.withdrawWithProof(ROUTE_ID, ROOT, bytes32(0), alice, beneficiary, 1_000_000, bytes32(0), "");

        vm.expectRevert(FxGhostWithdrawalRouter.ZeroAddress.selector);
        withdrawalRouter.withdrawWithProof(
            ROUTE_ID, ROOT, keccak256("nullifier"), address(0), beneficiary, 1_000_000, bytes32(0), ""
        );

        vm.expectRevert(FxGhostWithdrawalRouter.ZeroAmount.selector);
        withdrawalRouter.withdrawWithProof(
            ROUTE_ID, ROOT, keccak256("nullifier"), alice, beneficiary, 0, bytes32(0), ""
        );
    }

    function test_withdrawalRouter_rejectsInvalidRootProofAndPass() public {
        bytes32 nullifier = keccak256("invalid-withdraw-nullifier");

        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);
        vm.expectRevert(abi.encodeWithSelector(FxGhostWithdrawalRouter.InvalidRoot.selector, ROOT));
        withdrawalRouter.withdrawWithProof(ROUTE_ID, ROOT, nullifier, alice, beneficiary, 1_000_000, bytes32(0), "");

        registry.setRoot(ROOT, true, uint64(block.timestamp - 1), bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(FxGhostWithdrawalRouter.RootExpired.selector, ROOT, uint64(block.timestamp - 1))
        );
        withdrawalRouter.withdrawWithProof(ROUTE_ID, ROOT, nullifier, alice, beneficiary, 1_000_000, bytes32(0), "");

        registry.setRoot(ROOT, true, uint64(block.timestamp + 1 days), bytes32(0));
        pass.setPass(alice, MockBufiKycPass.Status.Revoked, 1);
        vm.expectRevert(abi.encodeWithSelector(FxGhostWithdrawalRouter.InvalidPass.selector, alice, 1, 1));
        withdrawalRouter.withdrawWithProof(ROUTE_ID, ROOT, nullifier, alice, beneficiary, 1_000_000, bytes32(0), "");

        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);
        withdrawalVerifier.setValid(false);
        vm.expectRevert(abi.encodeWithSelector(FxGhostWithdrawalRouter.InvalidWithdrawalProof.selector, nullifier));
        withdrawalRouter.withdrawWithProof(ROUTE_ID, ROOT, nullifier, alice, beneficiary, 1_000_000, bytes32(0), "");
    }

    function test_withdrawalRouter_enforcesKybRouteAndAdminConfig() public {
        registry.setRoot(ROOT, true, uint64(block.timestamp + 1 days), bytes32(0));
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.expectRevert(abi.encodeWithSelector(FxGhostWithdrawalRouter.InvalidPass.selector, alice, 1, 2));
        withdrawalRouter.withdrawWithProof(
            KYB_ROUTE_ID, ROOT, keccak256("kyb-withdraw"), alice, beneficiary, 1_000_000, bytes32(0), ""
        );

        vm.prank(alice);
        vm.expectRevert(FxGhostWithdrawalRouter.NotOwner.selector);
        withdrawalRouter.setWithdrawalRoute(ROUTE_ID, address(usdc), 1, false, bytes32(0));

        pass.setPass(alice, MockBufiKycPass.Status.Valid, 2);
        withdrawalRouter.withdrawWithProof(
            KYB_ROUTE_ID, ROOT, keccak256("kyb-withdraw"), alice, beneficiary, 1_000_000, bytes32(0), ""
        );
    }

    function test_publicFxSpokeStillWorks() public {
        bytes memory hubCalldata = hex"cafe";
        vm.startPrank(alice);
        usdc.approve(address(spoke), type(uint256).max);
        spoke.enterHub(address(usdc), 1_000_000, beneficiary, hubCalldata);
        vm.stopPrank();

        (uint256 amount,,,,,,, bytes memory hookData, bool withHook) = messenger.last();
        assertEq(amount, 1_000_000);
        assertTrue(withHook);
        assertEq(keccak256(hookData), keccak256(abi.encode(beneficiary, hubCalldata)));
    }

    function test_hookPermissionsDoNotEnableCustomSwapDeltas() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeAddLiquidity);
        assertTrue(permissions.beforeSwap);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
        assertFalse(permissions.beforeRemoveLiquidity);
    }

    function test_hookCallbacksRevertUnlessCalledByPoolManager() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.expectRevert(FxGhostKycHook.NotPoolManager.selector);
        hook.beforeSwap(trustedSwapRouter, _poolKey(), _swapParams(), _hookData(alice));
    }

    function test_hookEnforcesRouterAllowlistAndPass() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(FxGhostKycHook.UntrustedRouter.selector, untrustedSwapRouter));
        hook.beforeSwap(untrustedSwapRouter, _poolKey(), _swapParams(), _hookData(alice));

        vm.prank(poolManager);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(trustedSwapRouter, _poolKey(), _swapParams(), _hookData(alice));

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_hookTreatsSenderAsRouterAndUserFromHookData() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);
        pass.setPass(bob, MockBufiKycPass.Status.Revoked, 1);

        vm.prank(poolManager, bob);
        hook.beforeAddLiquidity(trustedSwapRouter, _poolKey(), _modifyParams(), _hookData(alice));

        vm.prank(poolManager, alice);
        vm.expectRevert(abi.encodeWithSelector(FxGhostKycHook.InvalidPass.selector, bob, 1, 1));
        hook.beforeAddLiquidity(trustedSwapRouter, _poolKey(), _modifyParams(), _hookData(bob));
    }

    function test_hookRejectsLowPassLevel() public {
        pass.setPass(alice, MockBufiKycPass.Status.Valid, 1);
        hook.setMinPassLevel(2);

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(FxGhostKycHook.InvalidPass.selector, alice, 1, 2));
        hook.beforeSwap(trustedSwapRouter, _poolKey(), _swapParams(), _hookData(alice));
    }

    function _hookData(address account) internal pure returns (bytes memory) {
        return abi.encode(
            FxGhostKycHook.GhostHookData({
                account: account, commitment: keccak256("hook-commitment"), nullifierHash: bytes32(0)
            })
        );
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(eurc)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
    }

    function _swapParams() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
    }

    function _modifyParams() internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});
    }
}
