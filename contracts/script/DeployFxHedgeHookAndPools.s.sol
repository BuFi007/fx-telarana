// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxHedgeHook} from "../src/hub/FxHedgeHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Phase 2 deployer for the BUFX LP hedge hook and demo pools.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///
/// Optional env:
///   POOL_MANAGER                     — defaults by chain for Arc/Fuji Phase 0
///   HOOK_ADMIN                       — defaults to deployer; must be deployer for configurePool in this script
///   USDC                             — defaults by chain
///   CIRBTC                           — defaults to Arc cirBTC on Arc
///   JPYC                             — defaults to official Arc JPYC on Arc
///   HEDGE_REBALANCE_THRESHOLD_E18    — defaults to 0.01 hedge-token unit
///   INITIALIZE_POOLS                 — defaults true
///   CIRBTC_USDC_FEE                  — defaults 3000
///   CIRBTC_USDC_TICK_SPACING         — defaults 60
///   CIRBTC_USDC_SQRT_PRICE_X96       — defaults BTC/USD ~= 100,000 with 8-dec cirBTC and 6-dec USDC
///   JPYC_USDC_FEE                    — defaults 100
///   JPYC_USDC_TICK_SPACING           — defaults 1
///   JPYC_USDC_SQRT_PRICE_X96         — defaults USD/JPY ~= 150 with 18-dec JPYC and 6-dec USDC
///   FX_HEDGE_HOOK_PATH               — defaults to ../deployments/fx-hedge-hook-<chainid>.json
contract DeployFxHedgeHookAndPools is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant HOOK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;
    uint256 internal constant FUJI_CHAIN_ID = 43_113;

    address internal constant ARC_POOL_MANAGER = 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E;
    address internal constant FUJI_POOL_MANAGER = 0x5A517f51edca02880542effb8b6a3bdFaAcaD8B2;
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant FUJI_USDC = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address internal constant ARC_CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
    address internal constant ARC_JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;

    bytes32 internal constant CIRBTC_MARKET_ID = keccak256("FX-PERP:cirBTC/USDC");
    bytes32 internal constant JPYC_MARKET_ID = keccak256("FX-PERP:JPYC/USDC");
    bytes32 internal constant PYTH_BTC_USD =
        0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant PYTH_JPY_USD =
        0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;

    uint160 internal constant CIRBTC_USDC_SQRT_PRICE_X96 = 2505414483750479311864138015;
    uint160 internal constant JPYC_USDC_SQRT_PRICE_X96 = 970342857091245926266988841461028654;
    uint256 internal constant DEFAULT_THRESHOLD_E18 = 0.01e18;

    error MissingRequiredAddress(string name);
    error HookAdminMustBeDeployer(address deployer, address hookAdmin);
    error TokensOutOfOrderOrEqual(address tokenA, address tokenB);

    struct PairConfig {
        string symbol;
        address asset;
        uint8 assetDecimals;
        bytes32 marketId;
        bytes32 pythFeedId;
        uint24 fee;
        int24 tickSpacing;
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
        address hookAdmin = vm.envOr("HOOK_ADMIN", deployer);
        if (hookAdmin != deployer) revert HookAdminMustBeDeployer(deployer, hookAdmin);

        address poolManager = vm.envOr("POOL_MANAGER", _defaultPoolManager());
        address usdc = vm.envOr("USDC", _defaultUsdc());
        address cirbtc = vm.envOr("CIRBTC", _defaultCirBtc());
        address jpyc = vm.envOr("JPYC", _defaultJpyc());
        _requireAddress("POOL_MANAGER", poolManager);
        _requireAddress("USDC", usdc);
        _requireAddress("CIRBTC", cirbtc);
        _requireAddress("JPYC", jpyc);

        uint256 threshold = vm.envOr("HEDGE_REBALANCE_THRESHOLD_E18", DEFAULT_THRESHOLD_E18);
        bool initializePools = vm.envOr("INITIALIZE_POOLS", true);
        PairConfig memory cirbtcConfig = PairConfig({
            symbol: "cirBTC",
            asset: cirbtc,
            assetDecimals: uint8(vm.envOr("CIRBTC_DECIMALS", uint256(8))),
            marketId: CIRBTC_MARKET_ID,
            pythFeedId: PYTH_BTC_USD,
            fee: uint24(vm.envOr("CIRBTC_USDC_FEE", uint256(3000))),
            tickSpacing: int24(int256(vm.envOr("CIRBTC_USDC_TICK_SPACING", int256(60)))),
            sqrtPriceX96: uint160(vm.envOr("CIRBTC_USDC_SQRT_PRICE_X96", uint256(CIRBTC_USDC_SQRT_PRICE_X96)))
        });
        PairConfig memory jpycConfig = PairConfig({
            symbol: "JPYC",
            asset: jpyc,
            assetDecimals: uint8(vm.envOr("JPYC_DECIMALS", uint256(18))),
            marketId: JPYC_MARKET_ID,
            pythFeedId: PYTH_JPY_USD,
            fee: uint24(vm.envOr("JPYC_USDC_FEE", uint256(100))),
            tickSpacing: int24(int256(vm.envOr("JPYC_USDC_TICK_SPACING", int256(1)))),
            sqrtPriceX96: uint160(vm.envOr("JPYC_USDC_SQRT_PRICE_X96", uint256(JPYC_USDC_SQRT_PRICE_X96)))
        });

        bytes memory creationCode = abi.encodePacked(
            type(FxHedgeHook).creationCode,
            abi.encode(IPoolManager(poolManager), hookAdmin, threshold)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(HOOK_CREATE2_FACTORY, _hookFlags(), creationCode, 500_000);

        console2.log("============================================");
        console2.log("Deploying FxHedgeHook + pools");
        console2.log("============================================");
        console2.log("chainId          ", block.chainid);
        console2.log("deployer         ", deployer);
        console2.log("poolManager      ", poolManager);
        console2.log("USDC             ", usdc);
        console2.log("cirBTC           ", cirbtc);
        console2.log("JPYC             ", jpyc);
        console2.log("expected hook    ", expectedHook);
        console2.log("initialize pools ", initializePools);
        console2.logBytes32(salt);

        vm.startBroadcast(pk);
        FxHedgeHook hook = _deployHook(expectedHook, salt, creationCode);
        PairDeployment memory cirbtcPool = _configurePair(poolManager, usdc, hook, cirbtcConfig, initializePools);
        PairDeployment memory jpycPool = _configurePair(poolManager, usdc, hook, jpycConfig, initializePools);
        vm.stopBroadcast();

        string memory defaultPath =
            string.concat("../deployments/fx-hedge-hook-", vm.toString(block.chainid), ".json");
        string memory path = vm.envOr("FX_HEDGE_HOOK_PATH", defaultPath);
        _writeManifest(
            path, deployer, poolManager, usdc, address(hook), salt, threshold, cirbtcConfig, cirbtcPool, jpycConfig, jpycPool
        );

        console2.log("============================================");
        console2.log("FxHedgeHook", address(hook));
        console2.log("cirBTC pool");
        console2.logBytes32(cirbtcPool.poolId);
        console2.log("JPYC pool");
        console2.logBytes32(jpycPool.poolId);
        console2.log("manifest", path);
        console2.log("============================================");
    }

    function _deployHook(address expected, bytes32 salt, bytes memory creationCode) internal returns (FxHedgeHook hook) {
        if (expected.code.length == 0) {
            (bool ok, bytes memory ret) = HOOK_CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode));
            require(ok, "FxHedgeHook CREATE2 failed");
            address actual;
            assembly {
                actual := mload(add(ret, 20))
            }
            require(actual == expected, "FxHedgeHook address mismatch");
        }
        hook = FxHedgeHook(expected);
    }

    function _configurePair(
        address poolManager,
        address usdc,
        FxHedgeHook hook,
        PairConfig memory config,
        bool initializePool
    ) internal returns (PairDeployment memory deployment) {
        deployment.key = _poolKey(usdc, config.asset, config.fee, config.tickSpacing, address(hook));
        deployment.poolId = PoolId.unwrap(deployment.key.toId());

        if (initializePool) {
            IPoolManager(poolManager).initialize(deployment.key, config.sqrtPriceX96);
            deployment.initialized = true;
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

    function _hookFlags() internal pure returns (uint160) {
        return uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    }

    function _defaultPoolManager() internal view returns (address) {
        if (block.chainid == ARC_CHAIN_ID) return ARC_POOL_MANAGER;
        if (block.chainid == FUJI_CHAIN_ID) return FUJI_POOL_MANAGER;
        return address(0);
    }

    function _defaultUsdc() internal view returns (address) {
        if (block.chainid == ARC_CHAIN_ID) return ARC_USDC;
        if (block.chainid == FUJI_CHAIN_ID) return FUJI_USDC;
        return address(0);
    }

    function _defaultCirBtc() internal view returns (address) {
        if (block.chainid == ARC_CHAIN_ID) return ARC_CIRBTC;
        return address(0);
    }

    function _defaultJpyc() internal view returns (address) {
        if (block.chainid == ARC_CHAIN_ID) return ARC_JPYC;
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
        bytes32 salt,
        uint256 threshold,
        PairConfig memory pair,
        PairDeployment memory deployment,
        PairConfig memory secondPair,
        PairDeployment memory secondDeployment
    ) internal {
        string memory root = "fxHedgeHook";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedBlockNumber", block.number);
        vm.serializeUint(root, "deployedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "PoolManager", poolManager);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeAddress(root, "FxHedgeHook", hook);
        vm.serializeAddress(root, "CREATE2Factory", HOOK_CREATE2_FACTORY);
        vm.serializeBytes32(root, "salt", salt);
        vm.serializeUint(root, "permissionFlagsLow14Bits", _hookFlags());
        vm.serializeUint(root, "defaultRebalanceThresholdE18", threshold);
        _serializePair(root, pair, deployment);
        string memory json = _serializePair(root, secondPair, secondDeployment);
        vm.writeJson(json, path);
    }

    function _serializePair(string memory root, PairConfig memory pair, PairDeployment memory deployment)
        internal
        returns (string memory json)
    {
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
        json = vm.serializeBool(root, string.concat(pair.symbol, "_initialized"), deployment.initialized);
    }
}
