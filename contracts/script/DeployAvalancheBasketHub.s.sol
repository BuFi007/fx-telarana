// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {FxTimelock} from "../src/governance/FxTimelock.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";

/// @notice Fresh Avalanche-shaped Hub deploy for Tenderly vnet and mainnet
///         rehearsal. Deploys the full Phase 3 basket against USDC:
///         JPYC, MXNB, AUDF, KRW1, ZCHF.
///
/// The script intentionally does every admin-gated action before timelock
/// handoff: oracle feed registration, Morpho market creation, receipt deploys,
/// v4 hook deploys, and pool initialization. Optional LP seeding is env-gated
/// and uses deployer balances only; no cheatcode minting occurs in broadcast.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY
///   AVALANCHE_MORPHO_BLUE
///   AVALANCHE_MORPHO_IRM
///
/// Optional env:
///   AVALANCHE_PYTH / AVALANCHE_POOL_MANAGER / AVALANCHE_CCTP_MESSAGE_TRANSMITTER
///   AVALANCHE_USDC / AVALANCHE_AUDF / AVALANCHE_JPYC / AVALANCHE_MXNB /
///   AVALANCHE_KRW1 / AVALANCHE_ZCHF
///   FX_HUB_LLTV                 default 0.86e18
///   FX_V4_FEE                   default 3000
///   FX_V4_TICK_SPACING          default 60
///   HOOK_OWNER                  default deployer
///   FXT_SEED_USDC_<SYMBOL>      optional raw token amount
///   FXT_SEED_<SYMBOL>           optional raw token amount
contract DeployAvalancheBasketHub is Script {
    using SafeERC20 for IERC20;

    address constant HOOK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant Q96 = 79228162514264337593543950336;

    address constant DEFAULT_AVAX_USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant DEFAULT_AVAX_AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address constant DEFAULT_AVAX_JPYC = 0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB;
    address constant DEFAULT_AVAX_KRW1 = 0x25A8ef2dF91F8ee0A98F261f4803a6EAb5fF0318;
    address constant DEFAULT_AVAX_MXNB = 0xF197FFC28c23E0309B5559e7a166f2c6164C80aA;
    address constant DEFAULT_AVAX_ZCHF = 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553;
    address constant DEFAULT_AVAX_PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    address constant DEFAULT_AVAX_POOL_MANAGER = 0x06380C0e0912312B5150364B9DC4542BA0DbBc85;
    address constant DEFAULT_AVAX_CCTP_MESSAGE_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    // Pyth feed ids are chain-agnostic.
    bytes32 constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_AUD_USD  = 0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80;
    bytes32 constant PYTH_USD_JPY  = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 constant PYTH_USD_KRW  = 0xe539120487c29b4defdf9a53d337316ea022a2688978a468f9efd847201be7e3;
    bytes32 constant PYTH_USD_MXN  = 0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;
    bytes32 constant PYTH_USD_CHF  = 0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8;

    bytes32 constant REDSTONE_USDC = "USDC";
    bytes32 constant REDSTONE_AUD = "AUD";
    bytes32 constant REDSTONE_JPY = "JPY";
    bytes32 constant REDSTONE_KRW = "KRW";
    bytes32 constant REDSTONE_MXN = "MXN";
    bytes32 constant REDSTONE_CHF = "CHF";

    struct AssetConfig {
        string symbol;
        address token;
        bytes32 pythFeed;
        bool pythInverted;
        bytes32 redstoneFeed;
    }

    struct Core {
        address deployer;
        address usdc;
        address morpho;
        address irm;
        address poolManager;
        address hookOwner;
        uint256 lltv;
        uint24 fee;
        int24 tickSpacing;
        FxOracle oracle;
        FxMarketRegistry registry;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc = vm.envOr("AVALANCHE_USDC", DEFAULT_AVAX_USDC);
        address pyth = vm.envOr("AVALANCHE_PYTH", DEFAULT_AVAX_PYTH);
        address morpho = vm.envAddress("AVALANCHE_MORPHO_BLUE");
        address irm = vm.envAddress("AVALANCHE_MORPHO_IRM");
        address poolManager = vm.envOr("AVALANCHE_POOL_MANAGER", DEFAULT_AVAX_POOL_MANAGER);
        address messageTransmitter =
            vm.envOr("AVALANCHE_CCTP_MESSAGE_TRANSMITTER", DEFAULT_AVAX_CCTP_MESSAGE_TRANSMITTER);
        address hookOwner = vm.envOr("HOOK_OWNER", deployer);
        uint256 lltv = vm.envOr("FX_HUB_LLTV", uint256(860000000000000000));
        uint24 fee = uint24(vm.envOr("FX_V4_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("FX_V4_TICK_SPACING", uint256(60))));

        AssetConfig[] memory assets = _assets();

        console2.log("======== fx-Telarana Avalanche basket Hub ========");
        console2.log("deployer     ", deployer);
        console2.log("usdc         ", usdc);
        console2.log("pyth         ", pyth);
        console2.log("morpho       ", morpho);
        console2.log("irm          ", irm);
        console2.log("pool manager ", poolManager);

        vm.startBroadcast(pk);

        _ensureMorphoConfig(IMorpho(morpho), irm, lltv, deployer);

        FxOracle oracle = new FxOracle(pyth, deployer, 300, 50, 30);
        oracle.setPythFeedConfig(usdc, PYTH_USDC_USD, false);
        oracle.setRedstoneFeed(usdc, REDSTONE_USDC);

        FxMarketRegistry registry = new FxMarketRegistry(morpho, deployer);
        FxLiquidator liquidator = new FxLiquidator(morpho, address(registry), address(oracle), deployer);
        FxHubMessageReceiver receiver = new FxHubMessageReceiver(messageTransmitter, usdc, address(registry));

        Core memory core = Core({
            deployer: deployer,
            usdc: usdc,
            morpho: morpho,
            irm: irm,
            poolManager: poolManager,
            hookOwner: hookOwner,
            lltv: lltv,
            fee: fee,
            tickSpacing: tickSpacing,
            oracle: oracle,
            registry: registry
        });

        for (uint256 i; i < assets.length; ++i) {
            _deployPair(core, assets[i]);
        }

        FxTimelock timelock = _deployTimelockAndHandoff(deployer, oracle, registry, liquidator);

        vm.stopBroadcast();

        _assertHandoff(address(timelock), deployer, oracle, registry, liquidator);

        console2.log("======== core deployed ========");
        console2.log("FxOracle            ", address(oracle));
        console2.log("FxMarketRegistry    ", address(registry));
        console2.log("FxLiquidator        ", address(liquidator));
        console2.log("FxHubMessageReceiver", address(receiver));
        console2.log("FxTimelock          ", address(timelock));
    }

    function _assets() internal view returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](5);
        assets[0] = AssetConfig({
            symbol: "JPYC",
            token: vm.envOr("AVALANCHE_JPYC", DEFAULT_AVAX_JPYC),
            pythFeed: PYTH_USD_JPY,
            pythInverted: true,
            redstoneFeed: REDSTONE_JPY
        });
        assets[1] = AssetConfig({
            symbol: "MXNB",
            token: vm.envOr("AVALANCHE_MXNB", DEFAULT_AVAX_MXNB),
            pythFeed: PYTH_USD_MXN,
            pythInverted: true,
            redstoneFeed: REDSTONE_MXN
        });
        assets[2] = AssetConfig({
            symbol: "AUDF",
            token: vm.envOr("AVALANCHE_AUDF", DEFAULT_AVAX_AUDF),
            pythFeed: PYTH_AUD_USD,
            pythInverted: false,
            redstoneFeed: REDSTONE_AUD
        });
        assets[3] = AssetConfig({
            symbol: "KRW1",
            token: vm.envOr("AVALANCHE_KRW1", DEFAULT_AVAX_KRW1),
            pythFeed: PYTH_USD_KRW,
            pythInverted: true,
            redstoneFeed: REDSTONE_KRW
        });
        assets[4] = AssetConfig({
            symbol: "ZCHF",
            token: vm.envOr("AVALANCHE_ZCHF", DEFAULT_AVAX_ZCHF),
            pythFeed: PYTH_USD_CHF,
            pythInverted: true,
            redstoneFeed: REDSTONE_CHF
        });
    }

    function _deployPair(Core memory core, AssetConfig memory asset) internal {
        core.oracle.setPythFeedConfig(asset.token, asset.pythFeed, asset.pythInverted);
        core.oracle.setRedstoneFeed(asset.token, asset.redstoneFeed);

        MorphoOracleAdapter adapterAssetLoan = new MorphoOracleAdapter(address(core.oracle), asset.token, core.usdc);
        MorphoOracleAdapter adapterUsdcLoan = new MorphoOracleAdapter(address(core.oracle), core.usdc, asset.token);

        IFxMarketRegistry.MarketParams memory assetLoan = IFxMarketRegistry.MarketParams({
            loanToken: asset.token,
            collateralToken: core.usdc,
            oracle: address(adapterAssetLoan),
            irm: core.irm,
            lltv: core.lltv
        });
        IFxMarketRegistry.MarketParams memory usdcLoan = IFxMarketRegistry.MarketParams({
            loanToken: core.usdc,
            collateralToken: asset.token,
            oracle: address(adapterUsdcLoan),
            irm: core.irm,
            lltv: core.lltv
        });

        bytes32 assetMarketId = core.registry.createAndRegisterMarket(assetLoan);
        bytes32 usdcMarketId = core.registry.createAndRegisterMarket(usdcLoan);

        new FxReceipt(
            IERC20(asset.token),
            string.concat("fx", asset.symbol, " supply receipt"),
            string.concat("fx", asset.symbol),
            core.morpho,
            _toMorpho(assetLoan)
        );
        new FxReceipt(
            IERC20(core.usdc),
            string.concat("fxUSDC-", asset.symbol, " supply receipt"),
            string.concat("fxUSDC-", asset.symbol),
            core.morpho,
            _toMorpho(usdcLoan)
        );

        FxSwapHook hook = _deployHook(core, asset.token);
        _initializePool(core.poolManager, core.usdc, asset.token, core.fee, core.tickSpacing, address(hook));
        _seedHookIfConfigured(core, asset, hook);

        console2.log("-------- pair --------");
        console2.log(asset.symbol);
        console2.log("token        ", asset.token);
        console2.log("adapter asset", address(adapterAssetLoan));
        console2.log("adapter usdc ", address(adapterUsdcLoan));
        console2.log("hook         ", address(hook));
        console2.logBytes32(assetMarketId);
        console2.logBytes32(usdcMarketId);
    }

    function _deployHook(Core memory core, address assetToken) internal returns (FxSwapHook hook) {
        (address token0, address token1) = _sort(core.usdc, assetToken);
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(core.poolManager, address(core.oracle), address(core.registry), core.hookOwner, token0, token1, core.morpho)
        );
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(HOOK_CREATE2_FACTORY, flags, creationCode, 500_000);
        (bool ok, bytes memory ret) = HOOK_CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode));
        require(ok, "hook CREATE2 failed");
        address actual;
        assembly {
            actual := mload(add(ret, 20))
        }
        require(actual == expected, "hook address mismatch");
        hook = FxSwapHook(actual);
    }

    function _initializePool(
        address poolManager,
        address usdc,
        address asset,
        uint24 fee,
        int24 tickSpacing,
        address hook
    ) internal {
        (address token0, address token1) = _sort(usdc, asset);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        IPoolManager(poolManager).initialize(key, Q96);
    }

    function _seedHookIfConfigured(Core memory core, AssetConfig memory asset, FxSwapHook hook) internal {
        uint256 usdcAmount = vm.envOr(string.concat("FXT_SEED_USDC_", asset.symbol), uint256(0));
        uint256 assetAmount = vm.envOr(string.concat("FXT_SEED_", asset.symbol), uint256(0));
        if (usdcAmount == 0 || assetAmount == 0) return;

        IERC20(core.usdc).forceApprove(address(hook), usdcAmount);
        IERC20(asset.token).forceApprove(address(hook), assetAmount);

        if (hook.TOKEN0() == core.usdc) {
            hook.deposit(usdcAmount, assetAmount);
        } else {
            hook.deposit(assetAmount, usdcAmount);
        }
    }

    function _ensureMorphoConfig(IMorpho morpho, address irm, uint256 lltv, address deployer) internal {
        address owner = morpho.owner();
        if (!morpho.isIrmEnabled(irm)) {
            require(owner == deployer, "IRM disabled and deployer is not Morpho owner");
            morpho.enableIrm(irm);
        }
        if (!morpho.isLltvEnabled(lltv)) {
            require(owner == deployer, "LLTV disabled and deployer is not Morpho owner");
            morpho.enableLltv(lltv);
        }
    }

    function _deployTimelockAndHandoff(
        address deployer,
        FxOracle oracle,
        FxMarketRegistry registry,
        FxLiquidator liquidator
    ) internal returns (FxTimelock timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        timelock = new FxTimelock(24 hours, proposers, executors, address(0));

        oracle.grantRole(oracle.DEFAULT_ADMIN_ROLE(), address(timelock));
        oracle.renounceRole(oracle.DEFAULT_ADMIN_ROLE(), deployer);
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(timelock));
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        liquidator.grantRole(liquidator.DEFAULT_ADMIN_ROLE(), address(timelock));
        liquidator.renounceRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _assertHandoff(
        address timelock,
        address deployer,
        FxOracle oracle,
        FxMarketRegistry registry,
        FxLiquidator liquidator
    ) internal view {
        require(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), timelock), "handoff: oracle admin != timelock");
        require(!oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), deployer), "handoff: deployer still oracle admin");
        require(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), timelock), "handoff: registry admin != timelock");
        require(!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), deployer), "handoff: deployer still registry admin");
        require(liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), timelock), "handoff: liq admin != timelock");
        require(!liquidator.hasRole(liquidator.DEFAULT_ADMIN_ROLE(), deployer), "handoff: deployer still liq admin");
    }

    function _toMorpho(IFxMarketRegistry.MarketParams memory p) internal pure returns (MorphoMarketParams memory) {
        return MorphoMarketParams({
            loanToken: p.loanToken,
            collateralToken: p.collateralToken,
            oracle: p.oracle,
            irm: p.irm,
            lltv: p.lltv
        });
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        require(a != b, "duplicate pair token");
        (token0, token1) = a < b ? (a, b) : (b, a);
    }
}
