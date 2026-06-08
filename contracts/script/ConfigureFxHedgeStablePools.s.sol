// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxHedgeHook} from "../src/hub/FxHedgeHook.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Configure/reconfigure the stablecoin FxHedgeHook pools on Arc testnet.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY             - must hold POOL_CONFIGURATOR_ROLE on FxHedgeHook
///
/// Optional env:
///   POOL_MANAGER                     - defaults to Arc hedge PoolManager
///   FX_HEDGE_HOOK                    - defaults to deployed Arc FxHedgeHook
///   INITIALIZE_POOLS                 - defaults true; already-initialized pools are skipped
///   FX_HEDGE_STABLE_POOLS_PATH       - defaults to ../deployments/fx-hedge-stable-pools-<chainid>.json
///   <SYMBOL>_USDC_SQRT_PRICE_X96     - override per-pair init price
contract ConfigureFxHedgeStablePools is Script {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant ARC_POOL_MANAGER = 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E;
    address internal constant ARC_FX_HEDGE_HOOK = 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540;
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARC_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant ARC_AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address internal constant ARC_MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address internal constant ARC_QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;

    bytes32 internal constant EURC_MARKET_ID =
        0x565a6e2fab61800aa18813603b5b485af5bed7dea1aa0845bdaa61502063cab8;
    bytes32 internal constant AUDF_MARKET_ID =
        0x921b564f97b14b7d73c12a72af4b7847fb5e3414f98cbe5fb5f1d8a3168c0a00;
    bytes32 internal constant MXNB_MARKET_ID =
        0xb698dfdbcbae088741081a53b9f1da11df8ff7c92c9278b66e15a34077ea5ca3;
    bytes32 internal constant QCAD_MARKET_ID =
        0x8ff4ca87809655d824803aa87eec8e3a7b15c73215aca5e72650c04072df4645;

    bytes32 internal constant PYTH_EURC_USD =
        0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;
    bytes32 internal constant PYTH_AUD_USD =
        0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80;
    bytes32 internal constant PYTH_USD_MXN =
        0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;
    bytes32 internal constant PYTH_USD_CAD =
        0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca;

    uint24 internal constant STABLE_FEE = 100;
    int24 internal constant STABLE_TICK_SPACING = 1;

    uint160 internal constant EURC_USDC_SQRT_PRICE_X96 = 75868981088120501468594700288;
    uint160 internal constant AUDF_USDC_SQRT_PRICE_X96 = 93528597258994576975634991168;
    uint160 internal constant MXNB_USDC_SQRT_PRICE_X96 = 329707881693095117678884186153;
    uint160 internal constant QCAD_USDC_SQRT_PRICE_X96 = 67689187350889761969455266752;

    error MissingRequiredAddress(string name);
    error TokensOutOfOrderOrEqual(address tokenA, address tokenB);

    struct PairConfig {
        string symbol;
        address asset;
        uint8 assetDecimals;
        bytes32 marketId;
        bytes32 pythFeedId;
        uint160 sqrtPriceX96;
    }

    struct PairDeployment {
        PoolKey key;
        bytes32 poolId;
        bool initialized;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address poolManager = vm.envOr("POOL_MANAGER", _defaultPoolManager());
        address hookAddr = vm.envOr("FX_HEDGE_HOOK", ARC_FX_HEDGE_HOOK);
        bool initializePools = vm.envOr("INITIALIZE_POOLS", true);
        _requireAddress("POOL_MANAGER", poolManager);
        _requireAddress("FX_HEDGE_HOOK", hookAddr);

        PairConfig[4] memory configs = [
            PairConfig({
                symbol: "EURC",
                asset: vm.envOr("EURC", ARC_EURC),
                assetDecimals: uint8(vm.envOr("EURC_DECIMALS", uint256(6))),
                marketId: EURC_MARKET_ID,
                pythFeedId: PYTH_EURC_USD,
                sqrtPriceX96: uint160(vm.envOr("EURC_USDC_SQRT_PRICE_X96", uint256(EURC_USDC_SQRT_PRICE_X96)))
            }),
            PairConfig({
                symbol: "AUDF",
                asset: vm.envOr("AUDF", ARC_AUDF),
                assetDecimals: uint8(vm.envOr("AUDF_DECIMALS", uint256(6))),
                marketId: AUDF_MARKET_ID,
                pythFeedId: PYTH_AUD_USD,
                sqrtPriceX96: uint160(vm.envOr("AUDF_USDC_SQRT_PRICE_X96", uint256(AUDF_USDC_SQRT_PRICE_X96)))
            }),
            PairConfig({
                symbol: "MXNB",
                asset: vm.envOr("MXNB", ARC_MXNB),
                assetDecimals: uint8(vm.envOr("MXNB_DECIMALS", uint256(6))),
                marketId: MXNB_MARKET_ID,
                pythFeedId: PYTH_USD_MXN,
                sqrtPriceX96: uint160(vm.envOr("MXNB_USDC_SQRT_PRICE_X96", uint256(MXNB_USDC_SQRT_PRICE_X96)))
            }),
            PairConfig({
                symbol: "QCAD",
                asset: vm.envOr("QCAD", ARC_QCAD),
                assetDecimals: uint8(vm.envOr("QCAD_DECIMALS", uint256(6))),
                marketId: QCAD_MARKET_ID,
                pythFeedId: PYTH_USD_CAD,
                sqrtPriceX96: uint160(vm.envOr("QCAD_USDC_SQRT_PRICE_X96", uint256(QCAD_USDC_SQRT_PRICE_X96)))
            })
        ];

        console2.log("============================================");
        console2.log("Configuring FxHedgeHook stable pools");
        console2.log("============================================");
        console2.log("chainId          ", block.chainid);
        console2.log("deployer         ", deployer);
        console2.log("poolManager      ", poolManager);
        console2.log("hook             ", hookAddr);
        console2.log("initialize pools ", initializePools);

        FxHedgeHook hook = FxHedgeHook(hookAddr);
        PairDeployment[4] memory deployments;
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < configs.length; i++) {
            deployments[i] = _configurePair(poolManager, ARC_USDC, hook, configs[i], initializePools);
        }
        vm.stopBroadcast();

        string memory defaultPath =
            string.concat("../deployments/fx-hedge-stable-pools-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("FX_HEDGE_STABLE_POOLS_PATH", defaultPath);
        _writeManifest(path, deployer, poolManager, ARC_USDC, hookAddr, configs, deployments);

        console2.log("manifest", path);
        console2.log("============================================");
    }

    function _configurePair(
        address poolManager,
        address usdc,
        FxHedgeHook hook,
        PairConfig memory config,
        bool initializePool
    ) internal returns (PairDeployment memory deployment) {
        deployment.key = _poolKey(usdc, config.asset, STABLE_FEE, STABLE_TICK_SPACING, address(hook));
        deployment.poolId = PoolId.unwrap(deployment.key.toId());

        if (initializePool) {
            (uint160 currentSqrtPriceX96,,,) =
                StateLibrary.getSlot0(IPoolManager(poolManager), PoolId.wrap(deployment.poolId));
            if (currentSqrtPriceX96 == 0) {
                IPoolManager(poolManager).initialize(deployment.key, config.sqrtPriceX96);
                deployment.initialized = true;
            } else {
                deployment.initialized = true;
                console2.log(config.symbol, "already initialized");
            }
        }

        hook.configurePool(
            deployment.key,
            config.marketId,
            config.asset,
            config.assetDecimals,
            config.pythFeedId,
            0,
            true
        );

        console2.log(config.symbol);
        console2.logBytes32(deployment.poolId);
    }

    function _poolKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hook)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address token0, address token1) = _sort(tokenA, tokenB);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        if (a == b) revert TokensOutOfOrderOrEqual(a, b);
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function _defaultPoolManager() internal view returns (address) {
        if (block.chainid == ARC_CHAIN_ID) return ARC_POOL_MANAGER;
        return address(0);
    }

    function _requireAddress(string memory name, address value) internal pure {
        if (value == address(0)) revert MissingRequiredAddress(name);
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address poolManager,
        address usdc,
        address hook,
        PairConfig[4] memory configs,
        PairDeployment[4] memory deployments
    ) internal {
        string memory root = "fxHedgeStablePools";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedBlockNumber", block.number);
        vm.serializeUint(root, "deployedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "PoolManager", poolManager);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeAddress(root, "FxHedgeHook", hook);
        for (uint256 i = 0; i < configs.length; i++) {
            _serializePair(root, configs[i], deployments[i]);
        }
        string memory json = vm.serializeString(root, "note", "FxHedgeHook stable pool configure manifest");
        vm.writeJson(json, path);
    }

    function _serializePair(string memory root, PairConfig memory pair, PairDeployment memory deployment) internal {
        vm.serializeAddress(root, string.concat(pair.symbol, "_asset"), pair.asset);
        vm.serializeUint(root, string.concat(pair.symbol, "_assetDecimals"), pair.assetDecimals);
        vm.serializeBytes32(root, string.concat(pair.symbol, "_marketId"), pair.marketId);
        vm.serializeBytes32(root, string.concat(pair.symbol, "_pythFeedId"), pair.pythFeedId);
        vm.serializeBytes32(root, string.concat(pair.symbol, "_poolId"), deployment.poolId);
        vm.serializeAddress(root, string.concat(pair.symbol, "_currency0"), Currency.unwrap(deployment.key.currency0));
        vm.serializeAddress(root, string.concat(pair.symbol, "_currency1"), Currency.unwrap(deployment.key.currency1));
        vm.serializeUint(root, string.concat(pair.symbol, "_fee"), deployment.key.fee);
        vm.serializeInt(root, string.concat(pair.symbol, "_tickSpacing"), deployment.key.tickSpacing);
        vm.serializeUint(root, string.concat(pair.symbol, "_sqrtPriceX96"), pair.sqrtPriceX96);
        vm.serializeBool(root, string.concat(pair.symbol, "_initialized"), deployment.initialized);
    }
}
