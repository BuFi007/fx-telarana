// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxSwapHook} from "../../src/hub/FxSwapHook.sol";
import {FxRouterSwapAdapter} from "../../src/hub/FxRouterSwapAdapter.sol";
import {SharedFxVault} from "../../src/vault/SharedFxVault.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

// Reuse the exact vault-backed mocks (no drift).
import {MockMorpho, MockOracle} from "./FxSwapHookVaultBacked.t.sol";

/// @notice Proves the production FxRouterSwapAdapter executes a cross-currency
///         exact-input swap through a vault-backed FxSwapHook pool — the
///         FxSwapHook Phase 2.5 swap path the FxRouter delegates to.
///
/// The adapter is the payer: the Router pre-transfers `sellAmountNet` to it,
/// then calls `swapExactInput`. These tests simulate that contract by
/// transferring the sell token to the adapter before each call (which is
/// exactly what FxRouter.executeIntent does via `safeTransfer`). FxRouter's own
/// Router→adapter surface is covered by test/FxRouter.t.sol against a mock
/// adapter; this file covers the adapter→pool surface against the real pool.
contract FxRouterSwapAdapterTest is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336; // sqrtPrice = 1.0

    address internal owner = address(this);
    address internal timelock = makeAddr("timelock");
    address internal routerCaller = makeAddr("routerCaller"); // stands in for FxRouter
    address internal recipient = makeAddr("recipient");

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockMorpho internal morpho;
    MockOracle internal oracle;

    PoolManager internal poolManager;
    SharedFxVault internal vault;
    FxSwapHook internal hook;
    FxRouterSwapAdapter internal adapter;
    PoolKey internal key;

    address internal token0; // sorted
    address internal token1;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        eurc = new MockERC20("Euro Coin", "EURC", 6);
        morpho = new MockMorpho();
        oracle = new MockOracle();

        (token0, token1) = _sort(address(usdc), address(eurc));

        poolManager = new PoolManager(owner);

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
            (IERC20(address(usdc)), owner, timelock, address(poolManager), address(oracle), IMorpho(address(morpho)), mkt)
        );
        vault = SharedFxVault(address(new ERC1967Proxy(address(impl), initData)));

        hook = _deployHook();
        key = _poolKey(address(hook));

        vault.allowHook(address(hook), true);
        vault.grantRole(vault.JUNIOR_ROLE(), address(this));
        _fundJunior(address(usdc), 100_000e6);
        _fundJunior(address(eurc), 100_000e6);

        hook.sync(_juniorOf(token0) * 1e12, _juniorOf(token1) * 1e12, 100);
        poolManager.initialize(key, Q96);

        // ---- The unit under test ----
        adapter = new FxRouterSwapAdapter(IPoolManager(address(poolManager)), owner);
        adapter.setAuthorizedCaller(routerCaller, true);
        // Register both directions against the same pool.
        adapter.setRoute(address(usdc), address(eurc), key, true);
        adapter.setRoute(address(eurc), address(usdc), key, true);
    }

    /// @notice Happy path: Router transfers USDC to the adapter, adapter swaps
    ///         USDC→EURC through the vault and delivers EURC to the recipient.
    function test_swapExactInput_routesThroughVaultToRecipient() public {
        uint256 amountIn = 1_000e6;
        uint256 juniorUsdcBefore = vault.juniorUsdcOf(address(hook));
        uint256 juniorEurcBefore = vault.juniorTokenBalanceOf(address(hook), address(eurc));
        uint256 seniorBefore = vault.seniorUsdcHot();

        // Router pre-transfers the sell token to the adapter, then calls.
        usdc.mint(routerCaller, amountIn);
        vm.startPrank(routerCaller);
        usdc.transfer(address(adapter), amountIn);
        uint256 buyAmount = adapter.swapExactInput(address(usdc), address(eurc), amountIn, 1, recipient);
        vm.stopPrank();

        assertGt(buyAmount, 0, "no output");
        assertEq(eurc.balanceOf(recipient), buyAmount, "recipient did not receive EURC");

        // Vault accounting: input credited to junior USDC, output drawn from junior EURC.
        assertEq(vault.juniorUsdcOf(address(hook)), juniorUsdcBefore + amountIn, "input not credited");
        assertEq(
            vault.juniorTokenBalanceOf(address(hook), address(eurc)), juniorEurcBefore - buyAmount, "output not drawn"
        );

        // Senior untouched.
        assertEq(vault.seniorUsdcHot(), seniorBefore, "senior touched");
        assertEq(seniorBefore, 0, "senior should be unfunded");

        // No token dust stranded anywhere.
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter retained USDC");
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter retained EURC");
        assertEq(usdc.balanceOf(address(poolManager)), 0, "PM retained USDC");
        assertEq(eurc.balanceOf(address(poolManager)), 0, "PM retained EURC");
    }

    /// @notice Reverse direction also routes (single PoolKey, opposite zeroForOne).
    function test_swapExactInput_reverseDirection() public {
        uint256 amountIn = 1_000e6;
        eurc.mint(routerCaller, amountIn);
        vm.startPrank(routerCaller);
        eurc.transfer(address(adapter), amountIn);
        uint256 buyAmount = adapter.swapExactInput(address(eurc), address(usdc), amountIn, 1, recipient);
        vm.stopPrank();
        assertGt(buyAmount, 0, "no output");
        assertEq(usdc.balanceOf(recipient), buyAmount, "recipient did not receive USDC");
    }

    function test_swapExactInput_revertsForUnauthorizedCaller() public {
        usdc.mint(address(this), 1_000e6);
        usdc.transfer(address(adapter), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(FxRouterSwapAdapter.NotAuthorizedCaller.selector, address(0xDEAD)));
        vm.prank(address(0xDEAD));
        adapter.swapExactInput(address(usdc), address(eurc), 1_000e6, 1, recipient);
    }

    function test_swapExactInput_revertsWhenRouteDisabled() public {
        // QCAD not configured.
        address qcad = address(0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d);
        vm.expectRevert(abi.encodeWithSelector(FxRouterSwapAdapter.RouteDisabled.selector, address(usdc), qcad));
        vm.prank(routerCaller);
        adapter.swapExactInput(address(usdc), qcad, 1_000e6, 1, recipient);
    }

    function test_swapExactInput_revertsUnderMinBuy() public {
        uint256 amountIn = 1_000e6;
        usdc.mint(routerCaller, amountIn);
        vm.startPrank(routerCaller);
        usdc.transfer(address(adapter), amountIn);
        // Demand an impossibly high output → adapter reverts inside the callback.
        vm.expectRevert();
        adapter.swapExactInput(address(usdc), address(eurc), amountIn, 10_000e6, recipient);
        vm.stopPrank();
    }

    function test_setRoute_revertsOnTokenMismatch() public {
        // key describes USDC/EURC; claiming it for an unrelated buyToken must revert.
        vm.expectRevert(FxRouterSwapAdapter.RouteTokenMismatch.selector);
        adapter.setRoute(address(usdc), address(0xABCD), key, true);
    }

    function test_setAuthorizedCaller_onlyOwner() public {
        vm.expectRevert();
        vm.prank(address(0xBEEF));
        adapter.setAuthorizedCaller(address(0xBEEF), true);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deployHook() internal returns (FxSwapHook deployed) {
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(
                address(poolManager), address(oracle), address(0x3333), owner, token0, token1, address(morpho), address(vault)
            )
        );
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, 500_000);
        deployed = new FxSwapHook{salt: salt}(
            address(poolManager), address(oracle), address(0x3333), owner, token0, token1, address(morpho), address(vault)
        );
        require(address(deployed) == expected, "hook addr mismatch");
    }

    function _poolKey(address hookAddress) internal view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
    }

    function _fundJunior(address token, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).approve(address(vault), amount);
        vault.fundJunior(address(hook), token, amount);
    }

    function _juniorOf(address token) internal view returns (uint256) {
        return token == address(usdc)
            ? vault.juniorUsdcOf(address(hook))
            : vault.juniorTokenBalanceOf(address(hook), token);
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }
}
