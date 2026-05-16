// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
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
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";
import {MockPyth} from "../test/mocks/MockPyth.sol";

/// @notice Tenderly Fuji-only persisted basket deployment drill.
///         This intentionally deploys mock stablecoins and MockPyth on the
///         Virtual TestNet, then persists every live address to a manifest.
///         It is not a mainnet script.
contract DeployTenderlyAvalancheBasket is Script {
    using SafeERC20 for IERC20;

    address constant HOOK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant Q96 = 79228162514264337593543950336;
    uint256 constant LLTV = 0.86e18;

    address constant DEFAULT_FUJI_MORPHO = 0xeF64621D41093144D9ED8aB8327eE381ECdB79E6;
    address constant DEFAULT_FUJI_IRM = 0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA;
    address constant DEFAULT_FUJI_CCTP_MT = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

    bytes32 constant FEED_USDC = keccak256("USDC");
    bytes32 constant FEED_AUDF = keccak256("AUDF");
    bytes32 constant FEED_JPYC = keccak256("JPYC");
    bytes32 constant FEED_MXNB = keccak256("MXNB");
    bytes32 constant FEED_KRW1 = keccak256("KRW1");
    bytes32 constant FEED_ZCHF = keccak256("ZCHF");

    struct AssetConfig {
        string symbol;
        string name;
        uint8 decimals_;
        bytes32 pythFeed;
        bool pythInverted;
        bytes32 redstoneFeed;
        int64 pythPrice;
        uint256 seedAsset;
    }

    struct PairDeployment {
        address token;
        address adapterAssetLoan;
        address adapterUsdcLoan;
        address receiptAsset;
        address receiptUsdc;
        address hook;
        bytes32 marketAssetLoan;
        bytes32 marketUsdcLoan;
    }

    struct Core {
        address deployer;
        MockStablecoin usdc;
        MockPyth pyth;
        IMorpho morpho;
        address irm;
        PoolManager poolManager;
        PoolSwapTest swapRouter;
        FxOracle oracle;
        FxMarketRegistry registry;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory manifestPath =
            vm.envOr("FXT_BASKET_MANIFEST", string("../deployments/tenderly-avalanche-fuji-basket.json"));

        address morphoAddr = vm.envOr("TENDERLY_BASKET_MORPHO", DEFAULT_FUJI_MORPHO);
        address irm = vm.envOr("TENDERLY_BASKET_IRM", DEFAULT_FUJI_IRM);
        address cctpMt = vm.envOr("TENDERLY_BASKET_CCTP_MT", DEFAULT_FUJI_CCTP_MT);

        require(block.chainid == 43113, "Tenderly basket drill expects Fuji chainId");
        require(morphoAddr.code.length != 0, "Morpho missing on vnet");
        require(irm.code.length != 0, "IRM missing on vnet");
        require(HOOK_CREATE2_FACTORY.code.length != 0, "CREATE2 factory missing");

        vm.startBroadcast(pk);

        IMorpho morpho = IMorpho(morphoAddr);
        _ensureMorphoConfig(morpho, irm, LLTV, deployer);

        MockPyth pyth = new MockPyth();
        MockStablecoin usdc = _deployToken("Tenderly USDC", "USDC", 6, deployer);
        _setPrice(pyth, FEED_USDC, 1_00_000_000, false);

        PoolManager poolManager = new PoolManager(deployer);
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        FxOracle oracle = new FxOracle(address(pyth), deployer, 300, 50, 30);
        oracle.setPythFeedConfig(address(usdc), FEED_USDC, false);
        oracle.setRedstoneFeed(address(usdc), bytes32("USDC"));

        FxMarketRegistry registry = new FxMarketRegistry(address(morpho), deployer);
        FxLiquidator liquidator = new FxLiquidator(address(morpho), address(registry), address(oracle), deployer);
        FxHubMessageReceiver receiver = new FxHubMessageReceiver(cctpMt, address(usdc), address(registry), deployer);

        Core memory core = Core({
            deployer: deployer,
            usdc: usdc,
            pyth: pyth,
            morpho: morpho,
            irm: irm,
            poolManager: poolManager,
            swapRouter: swapRouter,
            oracle: oracle,
            registry: registry
        });

        AssetConfig[] memory assets = _assets();
        PairDeployment[] memory pairs = new PairDeployment[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            pairs[i] = _deployPair(core, assets[i]);
        }

        FxTimelock timelock = _deployTimelockAndHandoff(deployer, oracle, registry, liquidator);

        vm.stopBroadcast();

        _assertHandoff(address(timelock), deployer, oracle, registry, liquidator);
        _writeManifest(
            manifestPath,
            deployer,
            cctpMt,
            core,
            liquidator,
            receiver,
            timelock,
            assets,
            pairs
        );

        console2.log("Tenderly basket manifest", manifestPath);
        console2.log("FxOracle", address(oracle));
        console2.log("FxMarketRegistry", address(registry));
        console2.log("PoolManager", address(poolManager));
        console2.log("PoolSwapTest", address(swapRouter));
    }

    function _assets() internal pure returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](5);
        assets[0] = AssetConfig("JPYC", "Tenderly JPYC", 18, FEED_JPYC, true, bytes32("JPY"), 156_25_000_000, 1_562_500e18);
        assets[1] = AssetConfig("MXNB", "Tenderly MXNB", 6, FEED_MXNB, true, bytes32("MXN"), 1_726_300_000, 172_630e6);
        assets[2] = AssetConfig("AUDF", "Tenderly AUDF", 6, FEED_AUDF, false, bytes32("AUD"), 71_909_500, 13_906e6);
        assets[3] = AssetConfig("KRW1", "Tenderly KRW1", 0, FEED_KRW1, true, bytes32("KRW"), 148_986_889_100, 14_898_689);
        assets[4] = AssetConfig("ZCHF", "Tenderly ZCHF", 18, FEED_ZCHF, true, bytes32("CHF"), 78_500_000, 7_850e18);
    }

    function _deployPair(Core memory core, AssetConfig memory asset)
        internal
        returns (PairDeployment memory pair)
    {
        MockStablecoin token = _deployToken(asset.name, asset.symbol, asset.decimals_, core.deployer);
        _setPrice(core.pyth, asset.pythFeed, asset.pythPrice, asset.pythInverted);
        core.oracle.setPythFeedConfig(address(token), asset.pythFeed, asset.pythInverted);
        core.oracle.setRedstoneFeed(address(token), asset.redstoneFeed);

        MorphoOracleAdapter adapterAssetLoan =
            new MorphoOracleAdapter(address(core.oracle), address(token), address(core.usdc));
        MorphoOracleAdapter adapterUsdcLoan =
            new MorphoOracleAdapter(address(core.oracle), address(core.usdc), address(token));

        IFxMarketRegistry.MarketParams memory assetLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(token),
            collateralToken: address(core.usdc),
            oracle: address(adapterAssetLoan),
            irm: core.irm,
            lltv: LLTV
        });
        IFxMarketRegistry.MarketParams memory usdcLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(core.usdc),
            collateralToken: address(token),
            oracle: address(adapterUsdcLoan),
            irm: core.irm,
            lltv: LLTV
        });

        bytes32 assetMarket = core.registry.createAndRegisterMarket(assetLoan);
        bytes32 usdcMarket = core.registry.createAndRegisterMarket(usdcLoan);

        FxReceipt receiptAsset = new FxReceipt(
            IERC20(address(token)),
            string.concat("fx", asset.symbol, " Tenderly supply receipt"),
            string.concat("fx", asset.symbol, "T"),
            address(core.morpho),
            _toMorpho(assetLoan)
        );
        FxReceipt receiptUsdc = new FxReceipt(
            IERC20(address(core.usdc)),
            string.concat("fxUSDC-", asset.symbol, " Tenderly supply receipt"),
            string.concat("fxUSDC-", asset.symbol, "T"),
            address(core.morpho),
            _toMorpho(usdcLoan)
        );

        FxSwapHook hook = _deployHook(core, address(token));
        _initializePool(address(core.poolManager), address(core.usdc), address(token), address(hook));
        _seedHook(core, token, asset.seedAsset, hook);

        pair = PairDeployment({
            token: address(token),
            adapterAssetLoan: address(adapterAssetLoan),
            adapterUsdcLoan: address(adapterUsdcLoan),
            receiptAsset: address(receiptAsset),
            receiptUsdc: address(receiptUsdc),
            hook: address(hook),
            marketAssetLoan: assetMarket,
            marketUsdcLoan: usdcMarket
        });
    }

    function _deployToken(string memory name, string memory symbol, uint8 decimals_, address owner)
        internal
        returns (MockStablecoin token)
    {
        token = new MockStablecoin(name, symbol, decimals_, owner);
        token.setFaucetOpen(true);
    }

    function _setPrice(MockPyth pyth, bytes32 feed, int64 price, bool) internal {
        pyth.setPrice(feed, price, 100, -8, block.timestamp);
    }

    function _deployHook(Core memory core, address assetToken) internal returns (FxSwapHook hook) {
        (address token0, address token1) = _sort(address(core.usdc), assetToken);
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(
                address(core.poolManager),
                address(core.oracle),
                address(core.registry),
                core.deployer,
                token0,
                token1,
                address(core.morpho)
            )
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

    function _initializePool(address poolManager, address usdc, address asset, address hook) internal {
        (address token0, address token1) = _sort(usdc, asset);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        IPoolManager(poolManager).initialize(key, Q96);
    }

    function _seedHook(Core memory core, MockStablecoin asset, uint256 assetAmount, FxSwapHook hook) internal {
        uint256 usdcAmount = 10_000e6;
        core.usdc.mint(core.deployer, usdcAmount);
        asset.mint(core.deployer, assetAmount);

        IERC20(address(core.usdc)).forceApprove(address(hook), usdcAmount);
        IERC20(address(asset)).forceApprove(address(hook), assetAmount);
        if (hook.TOKEN0() == address(core.usdc)) {
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

    function _writeManifest(
        string memory path,
        address deployer,
        address cctpMt,
        Core memory core,
        FxLiquidator liquidator,
        FxHubMessageReceiver receiver,
        FxTimelock timelock,
        AssetConfig[] memory assets,
        PairDeployment[] memory pairs
    ) internal {
        string memory root = "tenderly-avalanche-fuji-basket";
        vm.serializeString(root, "network", "tenderly-avalanche-fuji-basket");
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "MorphoBlue", address(core.morpho));
        vm.serializeAddress(root, "Irm", core.irm);
        vm.serializeAddress(root, "MockPyth", address(core.pyth));
        vm.serializeAddress(root, "USDC", address(core.usdc));
        vm.serializeAddress(root, "PoolManager", address(core.poolManager));
        vm.serializeAddress(root, "PoolSwapTest", address(core.swapRouter));
        vm.serializeAddress(root, "FxOracle", address(core.oracle));
        vm.serializeAddress(root, "FxMarketRegistry", address(core.registry));
        vm.serializeAddress(root, "FxLiquidator", address(liquidator));
        vm.serializeAddress(root, "FxHubMessageReceiver", address(receiver));
        vm.serializeAddress(root, "FxTimelock", address(timelock));
        vm.serializeAddress(root, "CctpMessageTransmitterV2", cctpMt);
        vm.serializeBytes32(root, "feed_USDC", FEED_USDC);

        for (uint256 i; i < assets.length; ++i) {
            string memory symbol = assets[i].symbol;
            vm.serializeAddress(root, string.concat("token_", symbol), pairs[i].token);
            vm.serializeAddress(root, string.concat("adapter_", symbol, "_assetLoan"), pairs[i].adapterAssetLoan);
            vm.serializeAddress(root, string.concat("adapter_", symbol, "_usdcLoan"), pairs[i].adapterUsdcLoan);
            vm.serializeAddress(root, string.concat("receipt_", symbol, "_asset"), pairs[i].receiptAsset);
            vm.serializeAddress(root, string.concat("receipt_", symbol, "_usdc"), pairs[i].receiptUsdc);
            vm.serializeAddress(root, string.concat("hook_", symbol), pairs[i].hook);
            vm.serializeBytes32(root, string.concat("market_", symbol, "_assetLoan"), pairs[i].marketAssetLoan);
            vm.serializeBytes32(root, string.concat("market_", symbol, "_usdcLoan"), pairs[i].marketUsdcLoan);
            vm.serializeBytes32(root, string.concat("feed_", symbol), assets[i].pythFeed);
            vm.serializeBool(root, string.concat("pythInverted_", symbol), assets[i].pythInverted);
            vm.serializeUint(root, string.concat("seedAsset_", symbol), assets[i].seedAsset);
        }

        string memory json = vm.serializeString(
            root,
            "notes",
            "Tenderly Fuji persisted basket drill. Mock stablecoins and MockPyth are testnet-only."
        );
        vm.writeJson(json, path);
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
