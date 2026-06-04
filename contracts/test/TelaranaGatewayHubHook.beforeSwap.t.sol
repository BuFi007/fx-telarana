// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {TelaranaGatewayHubHook} from "../src/hub/TelaranaGatewayHubHook.sol";
import {ITelaranaGatewayHubHook} from "../src/interfaces/ITelaranaGatewayHubHook.sol";
import {IHooks as ITelaranaIHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGatewayMinter} from "./mocks/MockGateway.sol";

/// @notice Minimal PoolManager mock — accepts `sync` + `settle` no-ops + IERC20
///         transfers in, lets us call the hook's IHooks surface directly.
///
///         The point: prove that the hook's `beforeSwap` implementation is
///         well-formed (auth, error paths, GatewayMinter call, BeforeSwapDelta
///         shape, event) WITHOUT spinning up real v4-core. Real-v4 attachment
///         is gated on salt-mining the hook address; the salt-mine script
///         (`script/MineHookSalt.s.sol`) lives separately.
contract MockPoolManager {
    address public lastSyncedCurrency;
    uint256 public lastSettledAmount;
    uint256 public settleCount;
    uint256 public syncCount;

    event MockSync(address currency);
    event MockSettle(uint256 amount);

    function sync(Currency currency) external {
        lastSyncedCurrency = Currency.unwrap(currency);
        syncCount += 1;
        emit MockSync(Currency.unwrap(currency));
    }

    function settle() external payable returns (uint256 paid) {
        paid = 0;
        settleCount += 1;
        emit MockSettle(paid);
    }
}

/// @notice GatewayMinter mock that mints (= transfers from its reserve) exactly
///         `mintAmount` USDC to its caller on `gatewayMint`. Differs from
///         MockGatewayMinter (which transfers to a configured recipient) — the
///         v4 hook path's `gatewayMint` is invoked BY the hook itself, so the
///         hook must receive the funds, which means the mint must land at
///         `msg.sender` (= hook).
contract MockSelfMintGatewayMinter {
    IERC20 public immutable USDC;

    bool public shouldRevert;
    uint256 public mintAmount;

    constructor(address usdc_) {
        USDC = IERC20(usdc_);
    }

    function setNextMint(bool revert_, uint256 amount_) external {
        shouldRevert = revert_;
        mintAmount = amount_;
    }

    function gatewayMint(bytes calldata, bytes calldata) external {
        if (shouldRevert) revert("scripted mint revert");
        if (mintAmount > 0) {
            // Mint to the caller (= the hook).
            require(USDC.transfer(msg.sender, mintAmount), "minter transfer failed");
        }
    }
}

contract TelaranaGatewayHubHookBeforeSwapTest is Test {
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                                FIXTURES
    //////////////////////////////////////////////////////////////*/

    TelaranaGatewayHubHook internal hook;
    MockPoolManager internal poolManager;
    MockSelfMintGatewayMinter internal minter;
    MockERC20 internal usdc;
    MockERC20 internal eurc;

    address internal admin = address(0xA11CE);
    address internal taker = address(0xBEEF);
    address internal sourceDepositor = address(0xCAFE);
    address internal sourceSigner = address(0xDEAD);
    address internal recipient = address(0xFEED);

    /// @notice canonical configured route + bound pool id
    bytes32 internal constant ROUTE_ID = bytes32(uint256(0xABCDEF));
    bytes32 internal constant REQUEST_ID = bytes32(uint256(0x1234567890));
    bytes32 internal constant SPOT_ROUTE_ID = bytes32(uint256(0x9999));
    bytes32 internal constant METADATA_REF = bytes32(uint256(0x1111));

    uint256 internal constant MINT_AMOUNT = 1_000_000; // 1 USDC

    PoolKey internal key;
    PoolId internal poolId;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        eurc = new MockERC20("Euro Coin", "EURC", 6);

        poolManager = new MockPoolManager();
        minter = new MockSelfMintGatewayMinter(address(usdc));

        vm.startPrank(admin);
        hook = new TelaranaGatewayHubHook(
            address(usdc),
            address(minter),
            address(poolManager),
            admin
        );
        vm.stopPrank();

        // Fund the minter so it can "mint" USDC by transferring from its reserve.
        usdc.mint(address(minter), 10_000_000); // 10 USDC

        // Set up the PoolKey: currency0 = EURC, currency1 = USDC (currency0 < currency1).
        // Make sure EURC address < USDC address; if not, swap.
        (Currency c0, Currency c1) = address(eurc) < address(usdc)
            ? (Currency.wrap(address(eurc)), Currency.wrap(address(usdc)))
            : (Currency.wrap(address(usdc)), Currency.wrap(address(eurc)));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        // Configure a Gateway hub route from a remote source domain.
        ITelaranaGatewayHubHook.GatewayHubRoute memory route = ITelaranaGatewayHubHook.GatewayHubRoute({
            sourceDomain: 1, // remote
            destinationDomain: 2, // local
            sourceUsdc: address(0xAAAA),
            destinationUsdc: address(usdc),
            sourceGatewayWallet: address(0xBBBB),
            destinationGatewayMinter: address(minter),
            destinationHub: address(hook),
            whitelistedCaller: address(0),
            signerMode: ITelaranaGatewayHubHook.GatewaySignerMode.EOA,
            enabled: true,
            metadataRef: METADATA_REF
        });

        vm.startPrank(admin);
        hook.setGatewayRoute(ROUTE_ID, route);
        hook.setPoolGatewayRoute(poolId, ROUTE_ID);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Real-Time FX Swap Pool Using Gateway — single-tx flow. We pose
    ///         as the PoolManager and call `beforeSwap` with the canonical
    ///         hookData payload. The hook must:
    ///           1. Call `GATEWAY_MINTER.gatewayMint(...)` (no CCTP polling).
    ///           2. Settle the minted USDC into the (mock) PoolManager.
    ///           3. Return a `BeforeSwapDelta` with the unspecified leg credited.
    ///           4. Emit `GatewayRoutedSwap`.
    ///           5. Record a SETTLED receipt for the requestId.
    function test_beforeSwap_happyPath_mintsAndSettles() public {
        minter.setNextMint(false, MINT_AMOUNT);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
        bytes memory hookData = abi.encode(bytes("attestation"), bytes("signature"), ctx);

        SwapParams memory params = _swapParamsBuyingUsdc();

        // Pre-state
        uint256 hookUsdcBefore = usdc.balanceOf(address(hook));
        uint256 minterUsdcBefore = usdc.balanceOf(address(minter));
        uint256 poolManagerUsdcBefore = usdc.balanceOf(address(poolManager));

        vm.recordLogs();
        vm.prank(address(poolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFee) = hook.beforeSwap(taker, key, params, hookData);

        // selector is IHooks.beforeSwap.selector
        assertEq(selector, IHooks.beforeSwap.selector, "selector");
        // lpFee untouched — hook does not override pool fee
        assertEq(lpFee, 0, "lp fee");
        // unspecifiedDelta = -MINT_AMOUNT (hook contributed USDC into pool accounting)
        int128 specified = BeforeSwapDeltaLibrary.getSpecifiedDelta(delta);
        int128 unspecified = BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta);
        assertEq(specified, int128(0), "specified delta == 0");
        assertEq(int256(unspecified), -int256(MINT_AMOUNT), "unspecified delta == -MINT_AMOUNT");

        // USDC physically moved from minter to PoolManager via the hook.
        assertEq(usdc.balanceOf(address(minter)), minterUsdcBefore - MINT_AMOUNT, "minter -= amount");
        assertEq(usdc.balanceOf(address(poolManager)), poolManagerUsdcBefore + MINT_AMOUNT, "PM += amount");
        // Hook balance returns to pre-state (mint -> transfer to PM in one beforeSwap).
        assertEq(usdc.balanceOf(address(hook)), hookUsdcBefore, "hook net 0");

        // PoolManager sync + settle observed
        assertEq(poolManager.syncCount(), 1, "sync called");
        assertEq(poolManager.settleCount(), 1, "settle called");
        assertEq(poolManager.lastSyncedCurrency(), address(usdc), "synced USDC");

        // Receipt recorded as SETTLED (v4 path is atomic)
        ITelaranaGatewayHubHook.GatewayReceipt memory r = hook.gatewayReceipt(REQUEST_ID);
        assertEq(uint256(r.state), uint256(ITelaranaGatewayHubHook.GatewayRequestState.SETTLED), "state SETTLED");
        assertEq(r.amount, MINT_AMOUNT, "receipt amount");

        // GatewayRoutedSwap event emitted (search for the topic — Foundry doesn't
        // pretty-print named topics for indexed parameters)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawGatewayRoutedSwap = false;
        bytes32 sig = keccak256("GatewayRoutedSwap(bytes32,bytes32,bytes32,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                sawGatewayRoutedSwap = true;
                break;
            }
        }
        assertTrue(sawGatewayRoutedSwap, "GatewayRoutedSwap fired");
    }

    /*//////////////////////////////////////////////////////////////
                            NEGATIVE PATHS  (Section J adv-uniswap-hooks)
    //////////////////////////////////////////////////////////////*/

    /// @notice Section A — only PoolManager can invoke IHooks callbacks.
    function test_beforeSwap_revertsWhen_notPoolManager() public {
        minter.setNextMint(false, MINT_AMOUNT);
        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
        bytes memory hookData = abi.encode(bytes("a"), bytes("s"), ctx);

        SwapParams memory params = _swapParamsBuyingUsdc();

        vm.prank(address(0x1337));
        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.NotPoolManager.selector, address(0x1337)));
        hook.beforeSwap(taker, key, params, hookData);
    }

    /// @notice Section A — no route bound for this PoolId.
    function test_beforeSwap_revertsWhen_routeUnset() public {
        // Clear the binding.
        vm.prank(admin);
        hook.clearPoolGatewayRoute(poolId);

        minter.setNextMint(false, MINT_AMOUNT);
        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
        bytes memory hookData = abi.encode(bytes("a"), bytes("s"), ctx);
        SwapParams memory params = _swapParamsBuyingUsdc();

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.PoolGatewayRouteUnset.selector, poolId));
        hook.beforeSwap(taker, key, params, hookData);
    }

    /// @notice Section J — fail closed if `mintForGateway` reverts. No partial
    ///         state, no half-settled deltas.
    function test_beforeSwap_revertsWhen_gatewayMintReverts() public {
        minter.setNextMint(true, MINT_AMOUNT); // scripted revert

        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
        bytes memory hookData = abi.encode(bytes("a"), bytes("s"), ctx);
        SwapParams memory params = _swapParamsBuyingUsdc();

        vm.prank(address(poolManager));
        vm.expectRevert(bytes("scripted mint revert"));
        hook.beforeSwap(taker, key, params, hookData);

        // Confirm no partial state: settle never called.
        assertEq(poolManager.settleCount(), 0, "no settle on revert");
    }

    /// @notice Section C — minted balance must equal `context.amount`. Defense
    ///         against minter shortfalls (denylist, expired spec, fee-on-transfer).
    function test_beforeSwap_revertsWhen_mintAmountMismatch() public {
        // Mint less than the context claims.
        minter.setNextMint(false, MINT_AMOUNT - 1);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
        bytes memory hookData = abi.encode(bytes("a"), bytes("s"), ctx);
        SwapParams memory params = _swapParamsBuyingUsdc();

        vm.prank(address(poolManager));
        vm.expectRevert(
            abi.encodeWithSelector(TelaranaGatewayHubHook.InvalidMintAmount.selector, MINT_AMOUNT, MINT_AMOUNT - 1)
        );
        hook.beforeSwap(taker, key, params, hookData);
    }

    /// @notice Section H — replay protection via `_gatewayReceipts`. A second
    ///         beforeSwap with the same requestId must revert.
    function test_beforeSwap_revertsWhen_duplicateRequestId() public {
        minter.setNextMint(false, MINT_AMOUNT);
        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
        bytes memory hookData = abi.encode(bytes("a"), bytes("s"), ctx);
        SwapParams memory params = _swapParamsBuyingUsdc();

        vm.prank(address(poolManager));
        hook.beforeSwap(taker, key, params, hookData);

        minter.setNextMint(false, MINT_AMOUNT);
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(TelaranaGatewayHubHook.DuplicateRequest.selector, REQUEST_ID));
        hook.beforeSwap(taker, key, params, hookData);
    }

    /// @notice Section G — admin-only binding.
    function test_setPoolGatewayRoute_revertsWhen_notAdmin() public {
        bytes32 newPool = bytes32(uint256(0x7777));
        vm.prank(taker);
        vm.expectRevert(); // OZ AccessControl reverts with AccessControlUnauthorizedAccount
        hook.setPoolGatewayRoute(PoolId.wrap(newPool), ROUTE_ID);
    }

    /// @notice Section J — pause kill switch disables the swap path.
    function test_beforeSwap_revertsWhen_paused() public {
        vm.prank(admin);
        hook.pause();

        minter.setNextMint(false, MINT_AMOUNT);
        ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
        bytes memory hookData = abi.encode(bytes("a"), bytes("s"), ctx);
        SwapParams memory params = _swapParamsBuyingUsdc();

        vm.prank(address(poolManager));
        vm.expectRevert();
        hook.beforeSwap(taker, key, params, hookData);
    }

    /// @notice Hook permission bits — must match the address-encoding contract.
    function test_getHookPermissions_matchesBeforeSwapPlusReturnsDelta() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertFalse(p.afterSwap, "afterSwap not enabled");
        assertFalse(p.beforeInitialize, "beforeInitialize not enabled");
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity not enabled");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _ctx(bytes32 requestId, uint256 amount)
        internal
        view
        returns (ITelaranaGatewayHubHook.GatewayMintContext memory)
    {
        return ITelaranaGatewayHubHook.GatewayMintContext({
            routeId: ROUTE_ID,
            requestId: requestId,
            action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_TO_HUB,
            sourceDepositor: sourceDepositor,
            sourceSigner: sourceSigner,
            recipient: recipient,
            tokenOut: address(0),
            amount: amount,
            minAmountOut: 0,
            spotRouteId: bytes32(0),
            metadataRef: METADATA_REF,
            hookData: bytes("")
        });
    }

    function _swapParamsBuyingUsdc() internal view returns (SwapParams memory) {
        // We need params such that the user "receives USDC". If USDC == currency0,
        // user pays currency1 → currency0, so zeroForOne = false.
        // If USDC == currency1, zeroForOne = true.
        bool usdcIsCurrency0 = Currency.unwrap(key.currency0) == address(usdc);
        return SwapParams({
            zeroForOne: usdcIsCurrency0 ? false : true,
            amountSpecified: -int256(MINT_AMOUNT), // exact input
            sqrtPriceLimitX96: 0
        });
    }
}
