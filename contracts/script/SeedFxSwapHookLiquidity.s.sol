// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal read surface of the on-chain AssetRegistry — the canonical
///         source of truth for per-chain token addresses. We never hardcode
///         token addresses in this script; we resolve them by symbol+chainId.
interface IAssetRegistry {
    function tokenAddressOnChain(string memory symbol, uint256 chainId) external view returns (address);
}

/// @notice FxSwapHook LP + introspection surface used by the seeder.
interface IFxSwapHook {
    function TOKEN0() external view returns (address);
    function TOKEN1() external view returns (address);
    function TOKEN0_DECIMALS() external view returns (uint8);
    function TOKEN1_DECIMALS() external view returns (uint8);
    function baseTargetE18() external view returns (uint256);
    function quoteTargetE18() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function deposit(uint256 amount0, uint256 amount1) external returns (uint256 shares);
}

/// @title  SeedFxSwapHookLiquidity
/// @notice Seeds an FxSwapHook PMM pool (e.g. USDC/EURC on Arc Testnet) with a
///         budget-capped, oracle-ratio-matched two-sided deposit. Tranche-1 of
///         the protocol liquidity bootstrap — driven by the on-chain
///         AssetRegistry so token addresses are never stale.
///
/// WHY this and not vanilla v4 modifyLiquidity:
///   FxSwapHook uses PMM custom accounting. LPs enter via `deposit(amount0,
///   amount1)` which mints shares pro-rata against the pool's tradable assets.
///   It pulls both tokens via transferFrom(msg.sender), so the broadcaster must
///   hold + approve both. (The JpycV4LiquiditySeeder unlock-callback dance is
///   only needed for the *FxHedgeHook* pools — JPYC/cirBTC — not here.)
///
/// RATIO: a non-first deposit mints shares = min(s0, s1). Depositing off the
///   pool's implied ratio just donates the excess side. We read the live
///   baseTargetE18/quoteTargetE18 and match it exactly so no value is donated.
///
/// SAFETY:
///   * Refuses any chain except Arc Testnet (5042002).
///   * Cross-checks the registry's USDC/quote addresses against the hook's
///     TOKEN0/TOKEN1 — aborts on mismatch (catches a wrong hook or stale config).
///   * Reverts (does not half-seed) if the broadcaster is short on either side,
///     printing exactly how much to fund.
///   * Optional expected-ratio guard (SEED_EXPECTED_QUOTE_PER_BASE_E18 +
///     SEED_RATIO_MAX_DRIFT_BPS) so a drifted/attacked pool can't silently
///     swallow the deposit at a bad price.
///
/// Required env:
///   KEEPER_PRIVATE_KEY            broadcaster; must hold USDC + quote token
///
/// Optional env:
///   ASSET_REGISTRY               default Arc AssetRegistry 0x7618…efc
///   FX_SWAP_HOOK                 default USDC/EURC hook 0xC6F894…0aC8
///   SEED_QUOTE_SYMBOL            default "EURC" (registry symbol of TOKEN1)
///   SEED_USDC_BUDGET             default 100_000e6 (100k USDC, 6-dec) — the cap
///   SEED_EXPECTED_QUOTE_PER_BASE_E18  if set (>0), assert live ratio within drift
///   SEED_RATIO_MAX_DRIFT_BPS     default 100 (1%) — only used if expected set
///
/// ⚠️  CANNOT BROADCAST ON ARC. Arc's native USDC (0x3600…) transferFrom calls
///     the Arc blocklist precompile at 0x1800…0001. `forge script` always runs
///     the whole run() body in its local EVM first (to capture the broadcast tx
///     set), and that local execution StackUnderflows on the precompile — so the
///     deposit reverts before any tx is sent, even with --skip-simulation. Use
///     this script for the DRY-RUN/reference path (registry + ratio resolution,
///     amount math, preflight). To actually broadcast, use the companion
///     `seed-fxswap-liquidity.sh`, which sends via `cast` (real-node gas
///     estimation, no local EVM). Verified live 2026-05-28: cast-send deposit of
///     1.0 USDC + 0.9 EURC minted 1,881,188 shares (tx 0xd44ec42…).
///
/// Dry-run (resolves registry/ratio, simulates up to the native-USDC transfer):
///   forge script script/SeedFxSwapHookLiquidity.s.sol --rpc-url $ARC_RPC_URL -vvv
contract SeedFxSwapHookLiquidity is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_ASSET_REGISTRY = 0x7618dFA920B6416b9924FAFBf5AA56a6FE978efC;
    address internal constant DEFAULT_FX_SWAP_HOOK    = 0xC6F894f30d0D28972C876B4af58C02A4E88A0aC8;
    uint256 internal constant DEFAULT_USDC_BUDGET     = 100_000e6;
    uint256 internal constant DEFAULT_MAX_DRIFT_BPS   = 100; // 1%

    function run() external {
        require(block.chainid == ARC_CHAIN_ID, "SeedFxSwapHook: Arc Testnet (5042002) only");

        uint256 pk = vm.envUint("KEEPER_PRIVATE_KEY");
        address broadcaster = vm.addr(pk);

        IAssetRegistry registry = IAssetRegistry(vm.envOr("ASSET_REGISTRY", DEFAULT_ASSET_REGISTRY));
        IFxSwapHook hook = IFxSwapHook(vm.envOr("FX_SWAP_HOOK", DEFAULT_FX_SWAP_HOOK));
        string memory quoteSymbol = vm.envOr("SEED_QUOTE_SYMBOL", string("EURC"));
        uint256 usdcBudget = vm.envOr("SEED_USDC_BUDGET", DEFAULT_USDC_BUDGET);

        // --- Resolve token addresses from the registry (source of truth) ---
        address usdc = registry.tokenAddressOnChain("USDC", ARC_CHAIN_ID);
        address quote = registry.tokenAddressOnChain(quoteSymbol, ARC_CHAIN_ID);
        require(usdc != address(0), "registry: USDC unset on Arc");
        require(quote != address(0), "registry: quote symbol unset on Arc");

        // --- Cross-check against the hook's configured pair ---
        address token0 = hook.TOKEN0();
        address token1 = hook.TOKEN1();
        require(token0 == usdc, "hook.TOKEN0 != registry USDC");
        require(token1 == quote, "hook.TOKEN1 != registry quote token");

        uint8 d0 = hook.TOKEN0_DECIMALS();
        uint8 d1 = hook.TOKEN1_DECIMALS();
        uint256 baseTargetE18 = hook.baseTargetE18();
        uint256 quoteTargetE18 = hook.quoteTargetE18();
        require(hook.totalShares() > 0, "pool not bootstrapped: run first owner deposit");
        require(baseTargetE18 > 0 && quoteTargetE18 > 0, "pool targets are zero");

        // --- Optional drift guard against expected oracle ratio ---
        _assertRatioWithinDrift(baseTargetE18, quoteTargetE18);

        // --- Compute the matched quote-side amount in E18 space, then back to native ---
        uint256 amount0 = usdcBudget; // USDC, 6-dec, the budget cap
        uint256 base0E18 = amount0 * (10 ** (18 - uint256(d0)));
        uint256 amount1E18 = (base0E18 * quoteTargetE18) / baseTargetE18;
        uint256 amount1 = amount1E18 / (10 ** (18 - uint256(d1))); // rounds down → quote is limiting side

        console2.log("chainId       ", block.chainid);
        console2.log("broadcaster   ", broadcaster);
        console2.log("hook          ", address(hook));
        console2.log("USDC (token0) ", usdc);
        console2.log("quote (token1)", quote);
        console2.log("ratio q/b E18 ", (quoteTargetE18 * 1e18) / baseTargetE18);
        console2.log("USDC amount0  ", amount0);
        console2.log("quote amount1 ", amount1);

        // --- Balance preflight: revert rather than half-seed ---
        uint256 bal0 = IERC20(usdc).balanceOf(broadcaster);
        uint256 bal1 = IERC20(quote).balanceOf(broadcaster);
        if (bal0 < amount0) {
            console2.log("SHORT USDC : have / need", bal0, amount0);
            revert("insufficient USDC: fund broadcaster up to SEED_USDC_BUDGET");
        }
        if (bal1 < amount1) {
            console2.log("SHORT quote: have / need", bal1, amount1);
            revert("insufficient quote token: fund broadcaster to matched ratio");
        }

        // --- Deposit ---
        vm.startBroadcast(pk);
        IERC20(usdc).forceApprove(address(hook), amount0);
        IERC20(quote).forceApprove(address(hook), amount1);
        uint256 shares = hook.deposit(amount0, amount1);
        IERC20(usdc).forceApprove(address(hook), 0);
        IERC20(quote).forceApprove(address(hook), 0);
        vm.stopBroadcast();

        console2.log("shares minted ", shares);
        console2.log("new totalShares", hook.totalShares());
        console2.log("new baseTargetE18 ", hook.baseTargetE18());
        console2.log("new quoteTargetE18", hook.quoteTargetE18());
    }

    function _assertRatioWithinDrift(uint256 baseTargetE18, uint256 quoteTargetE18) internal view {
        uint256 expected = vm.envOr("SEED_EXPECTED_QUOTE_PER_BASE_E18", uint256(0));
        if (expected == 0) return;
        uint256 maxDriftBps = vm.envOr("SEED_RATIO_MAX_DRIFT_BPS", DEFAULT_MAX_DRIFT_BPS);
        uint256 actual = (quoteTargetE18 * 1e18) / baseTargetE18;
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        require(diff * 10_000 <= expected * maxDriftBps, "pool ratio drifted beyond SEED_RATIO_MAX_DRIFT_BPS");
    }
}
