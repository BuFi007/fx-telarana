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

import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {SharedFxVault} from "../src/vault/SharedFxVault.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FxV4RouterHarness} from "./utils/FxV4RouterHarness.sol";

/// @dev Borrow-free Morpho stand-in (mirrors test/hub/FxSwapHookVaultBacked.t.sol).
///      The vault-backed swap path never touches Morpho (fills draw from the junior
///      buffer), so this only has to satisfy the vault's constructor/init wiring.
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
///      Always fresh (no staleness gate) so the fuzzer's oracle moves don't
///      trivially brick every fill; the per-swap / per-block notional caps in the
///      vault remain the meaningful safety boundary the swaps run against.
contract MockOracle {
    uint256 public rate = 1e18;

    function setRate(uint256 r) external {
        rate = r;
    }

    function getMid(address, address) external view returns (uint256, uint256) {
        return (rate, block.timestamp);
    }
}

/// @dev Stateful handler for the VAULT-BACKED swap path. It only drives the live
///      surface that still exists post-refactor: real v4 router settlement swaps in
///      both directions, plus oracle moves. `deposit`/`redeem` are gone (they revert
///      UseVault), so liquidity is seeded once in setUp via the vault. Swaps are
///      wrapped in try/catch: the vault enforces per-swap / per-block notional caps
///      and reverts stale-oracle fills, so a bounded swap legitimately no-ops under
///      those conditions — the invariants below must still hold either way.
contract FxSwapHookVaultInvariantHandler {
    FxSwapHook public immutable hook;
    FxV4RouterHarness public immutable router;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    MockOracle public immutable oracle;
    PoolKey public key;

    uint256 public immutable maxSwap0;
    uint256 public immutable maxSwap1;

    uint256 public midE18;

    constructor(
        FxSwapHook hook_,
        FxV4RouterHarness router_,
        MockERC20 token0_,
        MockERC20 token1_,
        MockOracle oracle_,
        PoolKey memory key_,
        uint256 maxSwap0_,
        uint256 maxSwap1_
    ) {
        hook = hook_;
        router = router_;
        token0 = token0_;
        token1 = token1_;
        oracle = oracle_;
        key = key_;
        midE18 = 1e18;
        maxSwap0 = maxSwap0_;
        maxSwap1 = maxSwap1_;

        token0.approve(address(router_), type(uint256).max);
        token1.approve(address(router_), type(uint256).max);
    }

    function swap0For1(uint256 rawAmountIn) external {
        uint256 amountIn = _bound(rawAmountIn, 1, maxSwap0);
        (uint256 quoted,) = hook.quoteExactInput(address(token0), amountIn);
        if (quoted == 0) return;

        token0.mint(address(this), amountIn);
        try router.swapExactInputSingle(key, true, amountIn, 1, address(this)) returns (uint256) {} catch {}
    }

    function swap1For0(uint256 rawAmountIn) external {
        uint256 amountIn = _bound(rawAmountIn, 1, maxSwap1);
        (uint256 quoted,) = hook.quoteExactInput(address(token1), amountIn);
        if (quoted == 0) return;

        token1.mint(address(this), amountIn);
        try router.swapExactInputSingle(key, false, amountIn, 1, address(this)) returns (uint256) {} catch {}
    }

    function moveOracle(uint256 rawMoveBps, bool up) external {
        uint256 moveBps = _bound(rawMoveBps, 1, 1_500);
        uint256 next =
            up ? (midE18 * (10_000 + moveBps)) / 10_000 : (midE18 * (10_000 - moveBps)) / 10_000;
        if (next == 0) return;
        midE18 = next;
        oracle.setRate(next); // moves the mid the hook/vault price against
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return min + (x % (max - min + 1));
        return x;
    }
}

/// @notice Stateful safety checks for the VAULT-BACKED v4 hook path.
///
/// The pre-refactor invariant suite asserted hook-owned Morpho-share bookkeeping
/// and self-custody hot-reserve targets. After the vault-backed refactor the hook
/// neither holds LP capital nor talks to Morpho on the swap path — liquidity lives
/// in SharedFxVault and fills draw from the junior buffer. Those old invariants no
/// longer describe the contract, so this suite is rebuilt on the proven vault-backed
/// flow (see test/hub/FxSwapHookVaultBacked.t.sol) and asserts the properties that
/// DO still matter:
///   1. the v4 PoolManager / router never retain pair tokens after settlement,
///   2. senior (lender) USDC is NEVER touched by a fill — it stays unfunded (0),
///   3. per-hook junior accounting stays internally consistent (USDC slice == the
///      global total since there is a single hook; FX slice == global total).
///
/// Compromise note: the handler drops the deposit/redeem actions (those functions
/// are permanently disabled post-refactor) and uses a MockOracle (no staleness) so
/// fuzzed oracle moves exercise pricing without bricking every fill. The vault's
/// notional caps are left enforcing, so swaps still run against a meaningful
/// boundary. This keeps the invariant exercising the live vault-backed swap path
/// rather than dead self-custody mechanics.
contract FxSwapHookInvariantTest is Test {
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

    address internal token0;
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
                address(poolManager),
                address(oracle),
                IMorpho(address(morpho)),
                mkt
            )
        );
        vault = SharedFxVault(address(new ERC1967Proxy(address(impl), initData)));

        hook = _deployHook();
        key = _poolKey(address(hook));

        // ---- Allowlist + fund the junior buffer for the hook (both sides) ----
        vault.allowHook(address(hook), true);
        vault.grantRole(vault.JUNIOR_ROLE(), address(this));
        _fundJunior(address(usdc), 1_000_000e6);
        _fundJunior(address(eurc), 1_000_000e6);

        // Seed PMM equilibrium targets from the vault reserves.
        hook.sync(_normE18(_juniorOf(token0)), _normE18(_juniorOf(token1)), 100);

        poolManager.initialize(key, Q96);

        _targetHandler();
    }

    /*//////////////////////////////////////////////////////////////
                                INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_routerAndPoolManagerDoNotRetainPairTokens() public view {
        assertEq(usdc.balanceOf(address(poolManager)), 0, "PoolManager retained USDC");
        assertEq(eurc.balanceOf(address(poolManager)), 0, "PoolManager retained EURC");
        assertEq(usdc.balanceOf(address(router)), 0, "router retained USDC");
        assertEq(eurc.balanceOf(address(router)), 0, "router retained EURC");
    }

    function invariant_seniorUsdcNeverTouchedByFills() public view {
        // No senior deposits were ever made → senior hot must stay 0 across all
        // fills. A fill that dipped into senior capital would break this.
        assertEq(vault.seniorUsdcHot(), 0, "senior USDC touched by a fill");
    }

    function invariant_perHookJuniorAccountingConsistent() public view {
        // Single hook → its junior slice must equal the global junior total for
        // each token (no cross-pool drift / double counting).
        assertEq(
            vault.juniorUsdcOf(address(hook)),
            _globalJuniorUsdc(),
            "USDC junior slice diverged from global total"
        );
        assertEq(
            vault.juniorTokenBalanceOf(address(hook), _fxToken()),
            _globalJuniorToken(_fxToken()),
            "FX junior slice diverged from global total"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _targetHandler() internal {
        FxSwapHookVaultInvariantHandler handler = new FxSwapHookVaultInvariantHandler({
            hook_: hook,
            router_: router,
            token0_: MockERC20(token0),
            token1_: MockERC20(token1),
            oracle_: oracle,
            key_: key,
            // Bound swaps well under the 20%-of-junior per-swap cap (junior = 1M).
            maxSwap0_: 50_000e6,
            maxSwap1_: 50_000e6
        });

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = FxSwapHookVaultInvariantHandler.swap0For1.selector;
        selectors[1] = FxSwapHookVaultInvariantHandler.swap1For0.selector;
        selectors[2] = FxSwapHookVaultInvariantHandler.moveOracle.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

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
                address(morpho),
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
        vault.fundJunior(address(hook), token, amount);
    }

    function _juniorOf(address token) internal view returns (uint256) {
        return token == address(usdc)
            ? vault.juniorUsdcOf(address(hook))
            : vault.juniorTokenBalanceOf(address(hook), token);
    }

    /// @dev The non-USDC pair token in this pool.
    function _fxToken() internal view returns (address) {
        return token0 == address(usdc) ? token1 : token0;
    }

    /// @dev Real global junior totals (vault aggregates across all hooks). With a
    ///      single hook these must equal that hook's slice — a genuine consistency
    ///      check on the vault's per-hook vs global bookkeeping under fuzzed fills.
    function _globalJuniorUsdc() internal view returns (uint256) {
        return vault.totalJuniorUsdc();
    }

    function _globalJuniorToken(address token) internal view returns (uint256) {
        return vault.totalJuniorTokenBalance(token);
    }

    function _normE18(uint256 raw) internal pure returns (uint256) {
        // Both pair tokens are 6-decimal in this test.
        return raw * 1e12;
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }
}
