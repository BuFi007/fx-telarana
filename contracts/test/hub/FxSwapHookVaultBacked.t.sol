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

import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {FxSwapHook} from "../../src/hub/FxSwapHook.sol";
import {SharedFxVault} from "../../src/vault/SharedFxVault.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FxV4RouterHarness} from "../utils/FxV4RouterHarness.sol";

/// @dev Borrow-free Morpho stand-in (mirrors test/vault/SharedFxVault.t.sol).
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

    function market(Id id) external view returns (Market memory) {
        return _market[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _pos[id][user];
    }
}

/// @dev FxOracle stand-in: getMid returns a settable mid (1e18 default = parity).
contract MockOracle {
    uint256 public rate = 1e18;

    function setRate(uint256 r) external {
        rate = r;
    }

    function getMid(address, address) external view returns (uint256, uint256) {
        return (rate, block.timestamp);
    }
}

/// @notice Proves a real Uniswap v4 swap routes its liquidity through the
///         SharedFxVault: the swap input lands in the vault (credited via
///         recordInflow) and the output is funded by the vault to the
///         PoolManager. Senior USDC is never touched by a fill.
contract FxSwapHookVaultBackedTest is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336; // sqrtPrice = 1.0

    address internal owner = address(this);
    address internal admin = address(this);
    address internal timelock = makeAddr("timelock");

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockMorpho internal morpho;
    MockOracle internal oracle;

    PoolManager internal poolManager;
    FxV4RouterHarness internal router;
    SharedFxVault internal vault;
    FxSwapHook internal hook;
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
        router = new FxV4RouterHarness(IPoolManager(address(poolManager)));

        // ---- Deploy the vault behind a UUPS proxy ----
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
            (
                IERC20(address(usdc)),
                admin,
                timelock,
                address(poolManager), // canonical PoolManager — fills may only route here
                address(oracle),
                IMorpho(address(morpho)),
                mkt
            )
        );
        vault = SharedFxVault(address(new ERC1967Proxy(address(impl), initData)));

        // ---- Deploy the vault-backed hook (mined salt) ----
        hook = _deployHook();
        key = _poolKey(address(hook));

        // ---- Allowlist + fund the junior buffer ----
        vault.allowHook(address(hook), true);
        vault.grantRole(vault.JUNIOR_ROLE(), address(this));
        _fundJunior(address(usdc), 100_000e6);
        _fundJunior(address(eurc), 100_000e6);

        // Seed PMM equilibrium targets from the vault reserves.
        hook.sync(_normE18(_juniorOf(token0)), _normE18(_juniorOf(token1)), 100);

        // ---- Initialize the v4 pool at parity ----
        poolManager.initialize(key, Q96);
    }

    /// @notice Real exact-input USDC→EURC swap routed through the vault.
    function test_swapRoutesThroughVault() public {
        bool zeroForOne = (token0 == address(usdc)); // selling USDC

        uint256 juniorUsdcBefore = vault.juniorUsdcOf(address(hook));
        uint256 juniorEurcBefore = vault.juniorTokenBalanceOf(address(hook), address(eurc));
        uint256 seniorBefore = vault.seniorUsdcHot();

        uint256 amountIn = 1_000e6;
        address trader = address(0xBEEF11);
        usdc.mint(trader, amountIn);

        vm.startPrank(trader);
        usdc.approve(address(router), type(uint256).max);
        uint256 amountOut = router.swapExactInputSingle(key, zeroForOne, amountIn, 1, trader);
        vm.stopPrank();

        // Trader received EURC output.
        assertGt(amountOut, 0, "no output");
        assertEq(eurc.balanceOf(trader), amountOut, "trader did not receive EURC");

        // Input was credited to the vault's junior USDC buffer (recordInflow).
        assertEq(
            vault.juniorUsdcOf(address(hook)),
            juniorUsdcBefore + amountIn,
            "input not credited to junior USDC"
        );

        // Output was funded by the vault's junior EURC inventory.
        assertEq(
            vault.juniorTokenBalanceOf(address(hook), address(eurc)),
            juniorEurcBefore - amountOut,
            "output not drawn from junior EURC"
        );

        // Senior (lender) USDC is NEVER touched by a fill.
        assertEq(vault.seniorUsdcHot(), seniorBefore, "senior USDC touched by fill");
        assertEq(seniorBefore, 0, "senior should be unfunded");

        // PoolManager + router retain no pair tokens after settlement.
        assertEq(usdc.balanceOf(address(poolManager)), 0, "PM retained USDC");
        assertEq(eurc.balanceOf(address(poolManager)), 0, "PM retained EURC");
        assertEq(usdc.balanceOf(address(router)), 0, "router retained USDC");
        assertEq(eurc.balanceOf(address(router)), 0, "router retained EURC");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deployHook() internal returns (FxSwapHook deployed) {
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(
                address(poolManager),
                address(oracle),
                address(0x3333), // registry — unused on the vault-backed swap path
                owner,
                token0,
                token1,
                address(morpho), // dead Morpho code stays compiling
                address(vault)
            )
        );
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, 500_000);
        deployed = new FxSwapHook{salt: salt}(
            address(poolManager),
            address(oracle),
            address(0x3333),
            owner,
            token0,
            token1,
            address(morpho),
            address(vault)
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
        // Per-hook allocation: fund the SWAP HOOK's slice (the hook is msg.sender on fills/inflows).
        vault.fundJunior(address(hook), token, amount);
    }

    function _juniorOf(address token) internal view returns (uint256) {
        return token == address(usdc)
            ? vault.juniorUsdcOf(address(hook))
            : vault.juniorTokenBalanceOf(address(hook), token);
    }

    function _normE18(uint256 raw) internal pure returns (uint256) {
        // Both pair tokens are 6-decimal in this test.
        return raw * 1e12;
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }
}
