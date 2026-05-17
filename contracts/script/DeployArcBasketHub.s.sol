// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxGatewayHook} from "../src/hub/FxGatewayHook.sol";
import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {FxTimelock} from "../src/governance/FxTimelock.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

/// @notice Arc testnet basket hub deploy for the money-market UI PoC.
/// @dev Deploys a fresh hub stack so all Morpho markets are registered during
///      bootstrap, before DEFAULT_ADMIN_ROLE is handed to FxTimelock.
///
/// Markets created:
///   EURC/USDC + USDC/EURC
///   mAUDF/USDC + USDC/mAUDF
///   mJPYC/USDC + USDC/mJPYC
///   mMXNB/USDC + USDC/mMXNB
///   mKRW1/USDC + USDC/mKRW1
///   mZCHF/USDC + USDC/mZCHF
contract DeployArcBasketHub is Script {
    using SafeERC20 for IERC20;

    address constant DEFAULT_USDC = 0x3600000000000000000000000000000000000000;
    address constant DEFAULT_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant DEFAULT_PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address constant DEFAULT_CCTP_MESSAGE_TRANSMITTER = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;
    address constant DEFAULT_GATEWAY_WALLET = 0x0077777d7EBA4688BDeF3E311b846F25870A19B9;
    address constant DEFAULT_GATEWAY_MINTER = 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B;

    bytes32 constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;
    bytes32 constant PYTH_AUD_USD = 0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80;
    bytes32 constant PYTH_USD_JPY = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 constant PYTH_USD_KRW = 0xe539120487c29b4defdf9a53d337316ea022a2688978a468f9efd847201be7e3;
    bytes32 constant PYTH_USD_MXN = 0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca;
    bytes32 constant PYTH_USD_CHF = 0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8;

    bytes32 constant REDSTONE_USDC = "USDC";
    bytes32 constant REDSTONE_EURC = "EURC";
    bytes32 constant REDSTONE_AUD = "AUD";
    bytes32 constant REDSTONE_JPY = "JPY";
    bytes32 constant REDSTONE_KRW = "KRW";
    bytes32 constant REDSTONE_MXN = "MXN";
    bytes32 constant REDSTONE_CHF = "CHF";

    struct AssetConfig {
        string symbol;
        string tokenName;
        uint8 decimals_;
        address token;
        bool mock;
        bytes32 pythFeed;
        bool pythInverted;
        bytes32 redstoneFeed;
        uint256 seedAssetRaw;
        uint256 walletMintRaw;
    }

    struct PairDeployment {
        address token;
        address adapterAssetLoan;
        address adapterUsdcLoan;
        address receiptAsset;
        address receiptUsdc;
        bytes32 marketAssetLoan;
        bytes32 marketUsdcLoan;
        uint256 suppliedAssetRaw;
        uint256 suppliedUsdcRaw;
    }

    struct Core {
        address deployer;
        address usdc;
        address morpho;
        address irm;
        uint256 lltv;
        uint256 seedUsdcRaw;
        FxOracle oracle;
        FxMarketRegistry registry;
    }

    error MissingArcMorphoAddress();
    error MissingArcIrmAddress();
    error InsufficientSeedBalance(address token, uint256 required, uint256 balance);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc = vm.envOr("ARC_USDC", DEFAULT_USDC);
        address eurc = vm.envOr("ARC_EURC", DEFAULT_EURC);
        address pyth = vm.envOr("ARC_PYTH", DEFAULT_PYTH);
        address messageTransmitter = vm.envOr("ARC_CCTP_MESSAGE_TRANSMITTER", DEFAULT_CCTP_MESSAGE_TRANSMITTER);
        address gatewayWallet = vm.envOr("ARC_GATEWAY_WALLET", DEFAULT_GATEWAY_WALLET);
        address gatewayMinter = vm.envOr("ARC_GATEWAY_MINTER", DEFAULT_GATEWAY_MINTER);
        address gatewayAuthority = vm.envOr("ARC_GATEWAY_AUTHORITY", deployer);
        address mockOwner = vm.envOr("ARC_BASKET_MOCK_OWNER", deployer);
        address morpho = vm.envAddress("ARC_MORPHO_BLUE");
        address irm = vm.envAddress("ARC_MORPHO_ADAPTIVE_IRM");
        uint256 lltv = vm.envOr("FX_HUB_LLTV", uint256(860000000000000000));
        // Arc native USDC checks an Arc precompile during transferFrom; Foundry's
        // local simulation cannot execute that precompile. Keep in-script USDC
        // seeding opt-in, then seed USDC markets post-deploy with direct live txs.
        uint256 seedUsdcRaw = vm.envOr("ARC_BASKET_SEED_USDC_RAW", uint256(0));
        bool openFaucets = vm.envOr("ARC_BASKET_OPEN_FAUCETS", true);
        string memory manifestPath = vm.envOr("ARC_BASKET_MANIFEST", string("../deployments/arc-testnet-basket.json"));

        if (morpho == address(0)) revert MissingArcMorphoAddress();
        if (irm == address(0)) revert MissingArcIrmAddress();

        AssetConfig[] memory assets = _assets(eurc);
        _assertSeedBalances(deployer, usdc, eurc, assets.length, seedUsdcRaw, assets[0].seedAssetRaw);

        console2.log("======== fx-Telarana Arc Basket Hub Deploy ========");
        console2.log("deployer       ", deployer);
        console2.log("mock owner     ", mockOwner);
        console2.log("morpho         ", morpho);
        console2.log("irm            ", irm);
        console2.log("usdc           ", usdc);
        console2.log("eurc           ", eurc);
        console2.log("pyth           ", pyth);
        console2.log("seed USDC raw  ", seedUsdcRaw);
        console2.log("faucets open   ", openFaucets);

        vm.startBroadcast(pk);

        FxOracle oracle = new FxOracle(pyth, deployer, 300, 50, 30);
        oracle.setFeed(usdc, PYTH_USDC_USD);
        oracle.setRedstoneFeed(usdc, REDSTONE_USDC);

        FxMarketRegistry registry = new FxMarketRegistry(morpho, deployer);

        Core memory core = Core({
            deployer: deployer,
            usdc: usdc,
            morpho: morpho,
            irm: irm,
            lltv: lltv,
            seedUsdcRaw: seedUsdcRaw,
            oracle: oracle,
            registry: registry
        });

        PairDeployment[] memory pairs = new PairDeployment[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i].mock) {
                assets[i].token = _deployMockToken(assets[i], deployer, mockOwner, openFaucets);
            }
            pairs[i] = _deployAndSeedPair(core, assets[i]);
        }

        FxLiquidator liquidator = new FxLiquidator(morpho, address(registry), address(oracle), deployer);
        FxHubMessageReceiver receiver = new FxHubMessageReceiver(messageTransmitter, usdc, address(registry), deployer);
        FxGatewayHook gatewayHook =
            new FxGatewayHook(usdc, gatewayWallet, gatewayMinter, address(receiver), 26, gatewayAuthority);
        receiver.setGatewayHook(address(gatewayHook));

        FxTimelock timelock = _deployTimelockAndHandoff(deployer, oracle, registry, liquidator);
        receiver.transferOwnership(address(timelock));

        vm.stopBroadcast();

        _assertHandoff(address(timelock), deployer, oracle, registry, liquidator);
        require(receiver.owner() == address(timelock), "receiver owner != timelock");
        require(receiver.gatewayHook() == address(gatewayHook), "receiver hook mismatch");
        require(gatewayHook.HUB() == address(receiver), "gateway hook hub mismatch");
        require(gatewayHook.authority() == gatewayAuthority, "gateway authority mismatch");

        _writeManifest(
            manifestPath,
            deployer,
            mockOwner,
            usdc,
            pyth,
            morpho,
            irm,
            messageTransmitter,
            gatewayWallet,
            gatewayMinter,
            gatewayAuthority,
            oracle,
            registry,
            liquidator,
            receiver,
            gatewayHook,
            timelock,
            assets,
            pairs
        );

        console2.log("================ deployed ================");
        console2.log("FxOracle              ", address(oracle));
        console2.log("FxMarketRegistry      ", address(registry));
        console2.log("FxLiquidator          ", address(liquidator));
        console2.log("FxHubMessageReceiver  ", address(receiver));
        console2.log("FxGatewayHook         ", address(gatewayHook));
        console2.log("FxTimelock            ", address(timelock));
        console2.log("manifest              ", manifestPath);
    }

    function _assets(address eurc) internal view returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](6);
        assets[0] = AssetConfig({
            symbol: "EURC",
            tokenName: "Circle EURC",
            decimals_: 6,
            token: eurc,
            mock: false,
            pythFeed: PYTH_EURC_USD,
            pythInverted: false,
            redstoneFeed: REDSTONE_EURC,
            seedAssetRaw: vm.envOr("ARC_BASKET_SEED_EURC_RAW", uint256(1_000_000)),
            walletMintRaw: 0
        });
        assets[1] = AssetConfig({
            symbol: "AUDF",
            tokenName: "Mock AUDF (test)",
            decimals_: 6,
            token: address(0),
            mock: true,
            pythFeed: PYTH_AUD_USD,
            pythInverted: false,
            redstoneFeed: REDSTONE_AUD,
            seedAssetRaw: vm.envOr("ARC_BASKET_SEED_AUDF_RAW", uint256(10_000e6)),
            walletMintRaw: vm.envOr("ARC_BASKET_WALLET_AUDF_RAW", uint256(1_000e6))
        });
        assets[2] = AssetConfig({
            symbol: "JPYC",
            tokenName: "Mock JPYC (test)",
            decimals_: 18,
            token: address(0),
            mock: true,
            pythFeed: PYTH_USD_JPY,
            pythInverted: true,
            redstoneFeed: REDSTONE_JPY,
            seedAssetRaw: vm.envOr("ARC_BASKET_SEED_JPYC_RAW", uint256(10_000e18)),
            walletMintRaw: vm.envOr("ARC_BASKET_WALLET_JPYC_RAW", uint256(1_000e18))
        });
        assets[3] = AssetConfig({
            symbol: "MXNB",
            tokenName: "Mock MXNB (test)",
            decimals_: 6,
            token: address(0),
            mock: true,
            pythFeed: PYTH_USD_MXN,
            pythInverted: true,
            redstoneFeed: REDSTONE_MXN,
            seedAssetRaw: vm.envOr("ARC_BASKET_SEED_MXNB_RAW", uint256(10_000e6)),
            walletMintRaw: vm.envOr("ARC_BASKET_WALLET_MXNB_RAW", uint256(1_000e6))
        });
        assets[4] = AssetConfig({
            symbol: "KRW1",
            tokenName: "Mock KRW1 (test)",
            decimals_: 0,
            token: address(0),
            mock: true,
            pythFeed: PYTH_USD_KRW,
            pythInverted: true,
            redstoneFeed: REDSTONE_KRW,
            seedAssetRaw: vm.envOr("ARC_BASKET_SEED_KRW1_RAW", uint256(10_000)),
            walletMintRaw: vm.envOr("ARC_BASKET_WALLET_KRW1_RAW", uint256(1_000))
        });
        assets[5] = AssetConfig({
            symbol: "ZCHF",
            tokenName: "Mock ZCHF (test)",
            decimals_: 18,
            token: address(0),
            mock: true,
            pythFeed: PYTH_USD_CHF,
            pythInverted: true,
            redstoneFeed: REDSTONE_CHF,
            seedAssetRaw: vm.envOr("ARC_BASKET_SEED_ZCHF_RAW", uint256(10_000e18)),
            walletMintRaw: vm.envOr("ARC_BASKET_WALLET_ZCHF_RAW", uint256(1_000e18))
        });
    }

    function _assertSeedBalances(
        address deployer,
        address usdc,
        address eurc,
        uint256 pairCount,
        uint256 seedUsdcRaw,
        uint256 seedEurcRaw
    ) internal view {
        uint256 requiredUsdc = pairCount * seedUsdcRaw;
        uint256 usdcBalance = IERC20(usdc).balanceOf(deployer);
        if (requiredUsdc > usdcBalance) revert InsufficientSeedBalance(usdc, requiredUsdc, usdcBalance);
        uint256 eurcBalance = IERC20(eurc).balanceOf(deployer);
        if (seedEurcRaw > eurcBalance) revert InsufficientSeedBalance(eurc, seedEurcRaw, eurcBalance);
    }

    function _deployMockToken(AssetConfig memory asset, address deployer, address mockOwner, bool openFaucets)
        internal
        returns (address tokenAddress)
    {
        MockStablecoin token =
            new MockStablecoin(asset.tokenName, string.concat("m", asset.symbol), asset.decimals_, deployer);
        uint256 mintAmount = asset.seedAssetRaw + asset.walletMintRaw;
        if (mintAmount > 0) token.mint(deployer, mintAmount);
        if (openFaucets) token.setFaucetOpen(true);
        if (mockOwner != deployer) token.transferOwnership(mockOwner);
        tokenAddress = address(token);
    }

    function _deployAndSeedPair(Core memory core, AssetConfig memory asset)
        internal
        returns (PairDeployment memory pair)
    {
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

        bytes32 assetMarket = core.registry.createAndRegisterMarket(assetLoan);
        bytes32 usdcMarket = core.registry.createAndRegisterMarket(usdcLoan);

        FxReceipt receiptAsset = new FxReceipt(
            IERC20(asset.token),
            string.concat("fx", asset.symbol, " supply receipt"),
            string.concat("fx", asset.symbol),
            core.morpho,
            _toMorpho(assetLoan)
        );
        FxReceipt receiptUsdc = new FxReceipt(
            IERC20(core.usdc),
            string.concat("fxUSDC-", asset.symbol, " supply receipt"),
            string.concat("fxUSDC-", asset.symbol),
            core.morpho,
            _toMorpho(usdcLoan)
        );

        if (asset.seedAssetRaw > 0) {
            IERC20(asset.token).forceApprove(address(core.registry), asset.seedAssetRaw);
            core.registry.supply(asset.token, core.usdc, asset.seedAssetRaw, core.deployer);
        }
        if (core.seedUsdcRaw > 0) {
            IERC20(core.usdc).forceApprove(address(core.registry), core.seedUsdcRaw);
            core.registry.supply(core.usdc, asset.token, core.seedUsdcRaw, core.deployer);
        }

        pair = PairDeployment({
            token: asset.token,
            adapterAssetLoan: address(adapterAssetLoan),
            adapterUsdcLoan: address(adapterUsdcLoan),
            receiptAsset: address(receiptAsset),
            receiptUsdc: address(receiptUsdc),
            marketAssetLoan: assetMarket,
            marketUsdcLoan: usdcMarket,
            suppliedAssetRaw: asset.seedAssetRaw,
            suppliedUsdcRaw: core.seedUsdcRaw
        });

        console2.log("-------- basket pair --------");
        console2.log(asset.symbol);
        console2.log("token       ", asset.token);
        console2.log("asset market");
        console2.logBytes32(assetMarket);
        console2.log("usdc market ");
        console2.logBytes32(usdcMarket);
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
        address mockOwner,
        address usdc,
        address pyth,
        address morpho,
        address irm,
        address messageTransmitter,
        address gatewayWallet,
        address gatewayMinter,
        address gatewayAuthority,
        FxOracle oracle,
        FxMarketRegistry registry,
        FxLiquidator liquidator,
        FxHubMessageReceiver receiver,
        FxGatewayHook gatewayHook,
        FxTimelock timelock,
        AssetConfig[] memory assets,
        PairDeployment[] memory pairs
    ) internal {
        string memory root = "arc-testnet-basket";
        vm.serializeString(root, "network", "arc-testnet");
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "mockOwner", mockOwner);
        vm.serializeAddress(root, "USDC", usdc);
        vm.serializeAddress(root, "Pyth", pyth);
        vm.serializeAddress(root, "MorphoBlue", morpho);
        vm.serializeAddress(root, "Irm", irm);
        vm.serializeAddress(root, "CctpMessageTransmitterV2", messageTransmitter);
        vm.serializeAddress(root, "GatewayWallet", gatewayWallet);
        vm.serializeAddress(root, "GatewayMinter", gatewayMinter);
        vm.serializeAddress(root, "GatewayAuthority", gatewayAuthority);
        vm.serializeAddress(root, "FxOracle", address(oracle));
        vm.serializeAddress(root, "FxMarketRegistry", address(registry));
        vm.serializeAddress(root, "FxLiquidator", address(liquidator));
        vm.serializeAddress(root, "FxHubMessageReceiver", address(receiver));
        vm.serializeAddress(root, "FxGatewayHook", address(gatewayHook));
        vm.serializeAddress(root, "FxTimelock", address(timelock));
        vm.serializeAddress(root, "receiverOwner", receiver.owner());
        vm.serializeUint(root, "poolCount", pairs.length * 2);

        for (uint256 i; i < assets.length; ++i) {
            string memory symbol = assets[i].symbol;
            vm.serializeAddress(root, string.concat("token_", symbol), pairs[i].token);
            vm.serializeBool(root, string.concat("mock_", symbol), assets[i].mock);
            vm.serializeUint(root, string.concat("decimals_", symbol), assets[i].decimals_);
            vm.serializeAddress(root, string.concat("adapter_", symbol, "_assetLoan"), pairs[i].adapterAssetLoan);
            vm.serializeAddress(root, string.concat("adapter_", symbol, "_usdcLoan"), pairs[i].adapterUsdcLoan);
            vm.serializeAddress(root, string.concat("receipt_", symbol, "_asset"), pairs[i].receiptAsset);
            vm.serializeAddress(root, string.concat("receipt_", symbol, "_usdc"), pairs[i].receiptUsdc);
            vm.serializeBytes32(root, string.concat("market_", symbol, "_assetLoan"), pairs[i].marketAssetLoan);
            vm.serializeBytes32(root, string.concat("market_", symbol, "_usdcLoan"), pairs[i].marketUsdcLoan);
            vm.serializeBytes32(root, string.concat("feed_", symbol), assets[i].pythFeed);
            vm.serializeBool(root, string.concat("pythInverted_", symbol), assets[i].pythInverted);
            vm.serializeUint(root, string.concat("supplied_", symbol, "_assetRaw"), pairs[i].suppliedAssetRaw);
            vm.serializeUint(root, string.concat("supplied_", symbol, "_usdcRaw"), pairs[i].suppliedUsdcRaw);
            vm.serializeUint(root, string.concat("walletMint_", symbol, "_raw"), assets[i].walletMintRaw);
        }

        string memory json = vm.serializeString(
            root,
            "notes",
            "Arc testnet basket hub for UI/API money-market testing. Mock AUDF/JPYC/MXNB/KRW1/ZCHF are testnet-only; receiver owner is timelock; Gateway authority remains pre-1271 EOA."
        );
        vm.writeJson(json, path);
    }

    function _toMorpho(IFxMarketRegistry.MarketParams memory p) internal pure returns (MorphoMarketParams memory) {
        return MorphoMarketParams({
            loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv
        });
    }
}
