// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Minimal v4 liquidity helper for FxHedgeHook pool seeding.
contract FxHedgeV4LiquiditySeeder is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    error NotPoolManager(address caller);

    struct SeedParams {
        address payer;
        address recipient;
        PoolKey key;
        ModifyLiquidityParams params;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function seed(
        address payer,
        address recipient,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        return abi.decode(
            manager.unlock(
                abi.encode(
                    SeedParams({
                        payer: payer,
                        recipient: recipient,
                        key: key,
                        params: params,
                        hookData: hookData
                    })
                )
            ),
            (BalanceDelta, BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager(msg.sender);

        SeedParams memory data = abi.decode(rawData, (SeedParams));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
            manager.modifyLiquidity(data.key, data.params, data.hookData);

        _resolve(data.key.currency0, data.payer, data.recipient, callerDelta.amount0());
        _resolve(data.key.currency1, data.payer, data.recipient, callerDelta.amount1());

        return abi.encode(callerDelta, feesAccrued);
    }

    function _resolve(Currency currency, address payer, address recipient, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, recipient, uint256(uint128(delta)));
        }
    }
}

/// @notice Seeds first liquidity for the six Arc testnet FxHedgeHook pools.
///
/// Required env:
///   KEEPER_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY
///
/// Optional shared env:
///   DEFAULT_TOKEN_SOURCE             - defaults to broadcaster
///   DEFAULT_USDC_SOURCE              - defaults to DEFAULT_TOKEN_SOURCE
///
/// Per-pair env. Pairs are JPYC_USDC, CIRBTC_USDC, EURC_USDC, AUDF_USDC,
/// MXNB_USDC, QCAD_USDC:
///   <PAIR>_LIQUIDITY_DELTA           - uint128-compatible liquidity delta; zero skips pair
///   <PAIR>_TOKEN0_CAP                - allowance cap for PoolKey.currency0
///   <PAIR>_TOKEN1_CAP                - allowance cap for PoolKey.currency1
///   <PAIR>_TOKEN0_SOURCE             - defaults to DEFAULT_TOKEN_SOURCE, except USDC defaults to DEFAULT_USDC_SOURCE
///   <PAIR>_TOKEN1_SOURCE             - defaults to DEFAULT_TOKEN_SOURCE, except USDC defaults to DEFAULT_USDC_SOURCE
///
/// Example:
///   JPYC_USDC_LIQUIDITY_DELTA=1000000000000000000 \
///   JPYC_USDC_TOKEN0_CAP=100000000000 \
///   JPYC_USDC_TOKEN1_CAP=1000000000000000000000000 \
///   forge script contracts/script/SeedFxHedgeHookLiquidity.s.sol:SeedFxHedgeHookLiquidity \
///     --root contracts --rpc-url $ARC_RPC_URL --broadcast -vv
contract SeedFxHedgeHookLiquidity is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant ARC_POOL_MANAGER = 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E;
    address internal constant FX_HEDGE_HOOK = 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540;
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;
    address internal constant CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
    address internal constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address internal constant MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address internal constant QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;

    uint24 internal constant STABLE_FEE = 100;
    int24 internal constant STABLE_TICK_SPACING = 1;
    uint24 internal constant CIRBTC_FEE = 3000;
    int24 internal constant CIRBTC_TICK_SPACING = 60;
    int24 internal constant FULL_RANGE_LOWER_SPACING_1 = -887_272;
    int24 internal constant FULL_RANGE_UPPER_SPACING_1 = 887_272;
    int24 internal constant FULL_RANGE_LOWER_SPACING_60 = -887_220;
    int24 internal constant FULL_RANGE_UPPER_SPACING_60 = 887_220;

    error UnsupportedChain(uint256 chainId);

    struct PairConfig {
        string symbol;
        string envPrefix;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
    }

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert UnsupportedChain(block.chainid);

        uint256 pk = vm.envOr("KEEPER_PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        require(pk != 0, "missing KEEPER_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY");

        address broadcaster = vm.addr(pk);
        address defaultSource = vm.envOr("DEFAULT_TOKEN_SOURCE", broadcaster);
        address defaultUsdcSource = vm.envOr("DEFAULT_USDC_SOURCE", defaultSource);

        console2.log("chainId     ", block.chainid);
        console2.log("broadcaster ", broadcaster);
        console2.log("PoolManager ", ARC_POOL_MANAGER);
        console2.log("FxHedgeHook ", FX_HEDGE_HOOK);

        PairConfig[6] memory pairs = [
            PairConfig({
                symbol: "JPYC/USDC",
                envPrefix: "JPYC_USDC",
                currency0: USDC,
                currency1: JPYC,
                fee: STABLE_FEE,
                tickSpacing: STABLE_TICK_SPACING,
                tickLower: FULL_RANGE_LOWER_SPACING_1,
                tickUpper: FULL_RANGE_UPPER_SPACING_1
            }),
            PairConfig({
                symbol: "cirBTC/USDC",
                envPrefix: "CIRBTC_USDC",
                currency0: USDC,
                currency1: CIRBTC,
                fee: CIRBTC_FEE,
                tickSpacing: CIRBTC_TICK_SPACING,
                tickLower: FULL_RANGE_LOWER_SPACING_60,
                tickUpper: FULL_RANGE_UPPER_SPACING_60
            }),
            PairConfig({
                symbol: "EURC/USDC",
                envPrefix: "EURC_USDC",
                currency0: USDC,
                currency1: EURC,
                fee: STABLE_FEE,
                tickSpacing: STABLE_TICK_SPACING,
                tickLower: FULL_RANGE_LOWER_SPACING_1,
                tickUpper: FULL_RANGE_UPPER_SPACING_1
            }),
            PairConfig({
                symbol: "AUDF/USDC",
                envPrefix: "AUDF_USDC",
                currency0: USDC,
                currency1: AUDF,
                fee: STABLE_FEE,
                tickSpacing: STABLE_TICK_SPACING,
                tickLower: FULL_RANGE_LOWER_SPACING_1,
                tickUpper: FULL_RANGE_UPPER_SPACING_1
            }),
            PairConfig({
                symbol: "MXNB/USDC",
                envPrefix: "MXNB_USDC",
                currency0: USDC,
                currency1: MXNB,
                fee: STABLE_FEE,
                tickSpacing: STABLE_TICK_SPACING,
                tickLower: FULL_RANGE_LOWER_SPACING_1,
                tickUpper: FULL_RANGE_UPPER_SPACING_1
            }),
            PairConfig({
                symbol: "QCAD/USDC",
                envPrefix: "QCAD_USDC",
                currency0: QCAD,
                currency1: USDC,
                fee: STABLE_FEE,
                tickSpacing: STABLE_TICK_SPACING,
                tickLower: FULL_RANGE_LOWER_SPACING_1,
                tickUpper: FULL_RANGE_UPPER_SPACING_1
            })
        ];

        vm.startBroadcast(pk);
        FxHedgeV4LiquiditySeeder seeder = new FxHedgeV4LiquiditySeeder(IPoolManager(ARC_POOL_MANAGER));
        for (uint256 i = 0; i < pairs.length; i++) {
            _seedPair(seeder, pairs[i], broadcaster, defaultSource, defaultUsdcSource);
        }
        vm.stopBroadcast();
    }

    function _seedPair(
        FxHedgeV4LiquiditySeeder seeder,
        PairConfig memory pair,
        address broadcaster,
        address defaultSource,
        address defaultUsdcSource
    ) internal {
        uint256 liquidityDelta = vm.envOr(string.concat(pair.envPrefix, "_LIQUIDITY_DELTA"), uint256(0));
        if (liquidityDelta == 0) {
            console2.log(pair.symbol, "skipped");
            return;
        }
        require(liquidityDelta <= uint256(type(uint128).max), "liquidity delta too large");

        uint256 token0Cap = vm.envOr(string.concat(pair.envPrefix, "_TOKEN0_CAP"), uint256(0));
        uint256 token1Cap = vm.envOr(string.concat(pair.envPrefix, "_TOKEN1_CAP"), uint256(0));
        require(token0Cap != 0 && token1Cap != 0, "missing token caps");

        address token0Source = _sourceFor(pair.envPrefix, "TOKEN0", pair.currency0, defaultSource, defaultUsdcSource);
        address token1Source = _sourceFor(pair.envPrefix, "TOKEN1", pair.currency1, defaultSource, defaultUsdcSource);

        _pullIfNeeded(pair.currency0, token0Source, broadcaster, token0Cap);
        _pullIfNeeded(pair.currency1, token1Source, broadcaster, token1Cap);

        IERC20(pair.currency0).forceApprove(address(seeder), token0Cap);
        IERC20(pair.currency1).forceApprove(address(seeder), token1Cap);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(pair.currency0),
            currency1: Currency.wrap(pair.currency1),
            fee: pair.fee,
            tickSpacing: pair.tickSpacing,
            hooks: IHooks(FX_HEDGE_HOOK)
        });

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: pair.tickLower,
            tickUpper: pair.tickUpper,
            liquidityDelta: int256(liquidityDelta),
            salt: bytes32(0)
        });

        (BalanceDelta callerDelta,) = seeder.seed(broadcaster, broadcaster, key, params, "");
        IERC20(pair.currency0).forceApprove(address(seeder), 0);
        IERC20(pair.currency1).forceApprove(address(seeder), 0);

        console2.log(pair.symbol, "seeded");
        console2.logInt(callerDelta.amount0());
        console2.logInt(callerDelta.amount1());
    }

    function _sourceFor(
        string memory envPrefix,
        string memory tokenSide,
        address token,
        address defaultSource,
        address defaultUsdcSource
    ) internal view returns (address) {
        address fallbackSource = token == USDC ? defaultUsdcSource : defaultSource;
        return vm.envOr(string.concat(envPrefix, "_", tokenSide, "_SOURCE"), fallbackSource);
    }

    function _pullIfNeeded(address token, address source, address recipient, uint256 amount) internal {
        if (amount == 0 || source == recipient) return;
        IERC20(token).safeTransferFrom(source, recipient, amount);
    }
}
