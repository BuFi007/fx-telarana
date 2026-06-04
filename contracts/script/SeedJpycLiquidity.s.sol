// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IFxSpotExecutorLiquidity {
    function addLiquidity(address token, uint256 amount) external;
}

/// @notice Minimal v4 liquidity helper used by the seeding script.
/// @dev PoolManager.unlock calls back into msg.sender, so a broadcast EOA
///      cannot add v4 liquidity directly. This helper settles the exact token
///      deltas owed by the LP after modifyLiquidity.
contract JpycV4LiquiditySeeder is IUnlockCallback {
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

/// @notice Seeds JPYC liquidity for the Hookathon dogfood path.
///
/// Required env:
///   KEEPER_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY
///   JPYC_SOURCE              wallet currently holding JPYC
///
/// Optional env:
///   ARC_JPYC_SOURCE          defaults to JPYC_SOURCE
///   FUJI_JPYC_SOURCE         defaults to JPYC_SOURCE
///   ARC_USDC_SOURCE          defaults to broadcaster
///   SEED_SPOT_JPYC_AMOUNT    JPYC atoms sent to FxSpotExecutor on Arc
///   SEED_MORPHO_JPYC_AMOUNT  JPYC atoms supplied to Fuji Morpho M5
///   SEED_V4_JPYC_AMOUNT      JPYC allowance cap for JPYC/USDC v4 seeding
///   SEED_V4_USDC_AMOUNT      USDC allowance cap for JPYC/USDC v4 seeding
///   SEED_V4_LIQUIDITY_DELTA  positive v4 liquidity delta for JPYC/USDC
///
/// Run one chain at a time:
///   forge script script/SeedJpycLiquidity.s.sol --rpc-url $ARC_RPC --broadcast -vvv
///   forge script script/SeedJpycLiquidity.s.sol --rpc-url $FUJI_RPC --broadcast -vvv
///
/// Note: JPYC seeds the JPYC/USDC pool. The cirBTC/USDC pool requires cirBTC
/// plus USDC, so this script intentionally does not send JPYC there.
contract SeedJpycLiquidity is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARC_CHAIN_ID = 5_042_002;
    uint256 internal constant FUJI_CHAIN_ID = 43_113;

    address internal constant JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant FUJI_USDC = 0x5425890298aed601595a70AB815c96711a31Bc65;

    address internal constant ARC_SPOT_EXECUTOR = 0x4e7372108529C0e7cb3aa0fF92B1c52e06e9e72f;
    address internal constant ARC_POOL_MANAGER = 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E;
    address internal constant FX_HEDGE_HOOK = 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540;

    address internal constant FUJI_MORPHO_BLUE = 0xeF64621D41093144D9ED8aB8327eE381ECdB79E6;
    address internal constant M5_ORACLE = 0x3229C7aaE05C62D35239b31691aae60A202E5428;
    address internal constant M5_IRM = 0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA;
    uint256 internal constant M5_LLTV = 860_000_000_000_000_000;

    uint24 internal constant JPYC_USDC_FEE = 100;
    int24 internal constant JPYC_USDC_TICK_SPACING = 1;
    int24 internal constant TICK_LOWER = -887_272;
    int24 internal constant TICK_UPPER = 887_272;

    function run() external {
        uint256 pk = vm.envOr("KEEPER_PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        require(pk != 0, "missing KEEPER_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY");

        address broadcaster = vm.addr(pk);
        address sharedJpycSource = vm.envAddress("JPYC_SOURCE");

        console2.log("chainId      ", block.chainid);
        console2.log("broadcaster  ", broadcaster);
        console2.log("JPYC source  ", sharedJpycSource);

        if (block.chainid == ARC_CHAIN_ID) {
            _seedArc(pk, broadcaster, sharedJpycSource);
        } else if (block.chainid == FUJI_CHAIN_ID) {
            _seedFuji(pk, broadcaster, sharedJpycSource);
        } else {
            revert("unsupported chain");
        }
    }

    function _seedArc(uint256 pk, address broadcaster, address sharedJpycSource) internal {
        address jpycSource = vm.envOr("ARC_JPYC_SOURCE", sharedJpycSource);
        address usdcSource = vm.envOr("ARC_USDC_SOURCE", broadcaster);

        uint256 spotJpycAmount = vm.envOr("SEED_SPOT_JPYC_AMOUNT", uint256(0));
        uint256 v4JpycCap = vm.envOr("SEED_V4_JPYC_AMOUNT", uint256(0));
        uint256 v4UsdcCap = vm.envOr("SEED_V4_USDC_AMOUNT", uint256(0));
        uint256 v4LiquidityDelta = vm.envOr("SEED_V4_LIQUIDITY_DELTA", uint256(0));

        vm.startBroadcast(pk);

        if (spotJpycAmount != 0) {
            _pullIfNeeded(JPYC, jpycSource, broadcaster, spotJpycAmount);
            IERC20(JPYC).forceApprove(ARC_SPOT_EXECUTOR, spotJpycAmount);
            IFxSpotExecutorLiquidity(ARC_SPOT_EXECUTOR).addLiquidity(JPYC, spotJpycAmount);
            IERC20(JPYC).forceApprove(ARC_SPOT_EXECUTOR, 0);
            console2.log("seeded FxSpotExecutor JPYC", spotJpycAmount);
        }

        if (v4LiquidityDelta != 0) {
            require(v4LiquidityDelta <= uint256(type(uint128).max), "liquidity delta too large");
            require(v4JpycCap != 0 && v4UsdcCap != 0, "missing v4 token caps");

            _pullIfNeeded(JPYC, jpycSource, broadcaster, v4JpycCap);
            _pullIfNeeded(ARC_USDC, usdcSource, broadcaster, v4UsdcCap);

            JpycV4LiquiditySeeder seeder = new JpycV4LiquiditySeeder(IPoolManager(ARC_POOL_MANAGER));

            IERC20(JPYC).forceApprove(address(seeder), v4JpycCap);
            IERC20(ARC_USDC).forceApprove(address(seeder), v4UsdcCap);

            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(ARC_USDC),
                currency1: Currency.wrap(JPYC),
                fee: JPYC_USDC_FEE,
                tickSpacing: JPYC_USDC_TICK_SPACING,
                hooks: IHooks(FX_HEDGE_HOOK)
            });

            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(v4LiquidityDelta),
                salt: bytes32(0)
            });

            (BalanceDelta callerDelta,) = seeder.seed(broadcaster, broadcaster, key, params, "");
            IERC20(JPYC).forceApprove(address(seeder), 0);
            IERC20(ARC_USDC).forceApprove(address(seeder), 0);

            console2.log("seeded JPYC/USDC v4 liquidity");
            console2.logInt(callerDelta.amount0());
            console2.logInt(callerDelta.amount1());
        }

        vm.stopBroadcast();
    }

    function _seedFuji(uint256 pk, address broadcaster, address sharedJpycSource) internal {
        address jpycSource = vm.envOr("FUJI_JPYC_SOURCE", sharedJpycSource);
        uint256 morphoJpycAmount = vm.envOr("SEED_MORPHO_JPYC_AMOUNT", uint256(0));

        vm.startBroadcast(pk);

        if (morphoJpycAmount != 0) {
            _pullIfNeeded(JPYC, jpycSource, broadcaster, morphoJpycAmount);
            IERC20(JPYC).forceApprove(FUJI_MORPHO_BLUE, morphoJpycAmount);

            MarketParams memory m5 = MarketParams({
                loanToken: JPYC,
                collateralToken: FUJI_USDC,
                oracle: M5_ORACLE,
                irm: M5_IRM,
                lltv: M5_LLTV
            });

            (uint256 assetsSupplied, uint256 sharesSupplied) =
                IMorpho(FUJI_MORPHO_BLUE).supply(m5, morphoJpycAmount, 0, broadcaster, "");
            IERC20(JPYC).forceApprove(FUJI_MORPHO_BLUE, 0);

            console2.log("seeded Fuji Morpho M5 JPYC assets", assetsSupplied);
            console2.log("seeded Fuji Morpho M5 shares     ", sharesSupplied);
        }

        vm.stopBroadcast();
    }

    function _pullIfNeeded(address token, address source, address recipient, uint256 amount) internal {
        if (amount == 0 || source == recipient) return;
        IERC20(token).safeTransferFrom(source, recipient, amount);
    }
}
