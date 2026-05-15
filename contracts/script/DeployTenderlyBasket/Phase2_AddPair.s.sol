// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BasketDeployBase} from "./BasketDeployBase.sol";

import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import {FxOracle} from "../../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../../src/hub/FxReceipt.sol";
import {FxSwapHook} from "../../src/hub/FxSwapHook.sol";
import {MorphoOracleAdapter} from "../../src/hub/MorphoOracleAdapter.sol";
import {IFxMarketRegistry} from "../../src/interfaces/IFxMarketRegistry.sol";
import {MockStablecoin} from "../../src/test-helpers/MockStablecoin.sol";
import {MockPyth} from "../../test/mocks/MockPyth.sol";

/// @notice Phase 2: deploys a single basket pair (mock token + 2 adapters +
///         2 markets + 2 receipts + hook + pool init + seed). Asset symbol
///         is read from `FXT_PHASE_ASSET` env (one of JPYC/MXNB/AUDF/KRW1/ZCHF).
///         Reads Phase 1 outputs from the consolidated manifest file.
///         Emits `phase2-<symbol>.json`.
///
/// Tenderly Pro TUs budget: ~17 txs per asset. Borderline — driver script
/// must sleep 60s between Phase 2 invocations.
contract Phase2_AddPair is BasketDeployBase {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory symbol = vm.envString("FXT_PHASE_ASSET");
        AssetConfig memory asset = _assetFor(symbol);

        require(
            block.chainid == 43113 || block.chainid == 5042002,
            "Phase2: testnet-only (Fuji 43113 or Arc 5042002)"
        );

        // Look up Phase 1 deployments via merged manifest.
        address morphoAddr = _readManifestAddress("MorphoBlue");
        address irm = _readManifestAddress("Irm");
        address pythAddr = _readManifestAddress("MockPyth");
        address usdcAddr = _readManifestAddress("USDC");
        address poolManagerAddr = _readManifestAddress("PoolManager");
        address oracleAddr = _readManifestAddress("FxOracle");
        address registryAddr = _readManifestAddress("FxMarketRegistry");

        MockPyth pyth = MockPyth(pythAddr);
        MockStablecoin usdc = MockStablecoin(usdcAddr);
        FxOracle oracle = FxOracle(oracleAddr);
        FxMarketRegistry registry = FxMarketRegistry(registryAddr);
        IMorpho morpho = IMorpho(morphoAddr);

        vm.startBroadcast(pk);

        MockStablecoin token = _deployToken(asset.name, asset.symbol, asset.decimals_, deployer);
        _setPrice(pyth, asset.pythFeed, asset.pythPrice);
        oracle.setPythFeedConfig(address(token), asset.pythFeed, asset.pythInverted);
        oracle.setRedstoneFeed(address(token), asset.redstoneFeed);

        MorphoOracleAdapter adapterAssetLoan =
            new MorphoOracleAdapter(address(oracle), address(token), address(usdc));
        MorphoOracleAdapter adapterUsdcLoan =
            new MorphoOracleAdapter(address(oracle), address(usdc), address(token));

        IFxMarketRegistry.MarketParams memory assetLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(token),
            collateralToken: address(usdc),
            oracle: address(adapterAssetLoan),
            irm: irm,
            lltv: LLTV
        });
        IFxMarketRegistry.MarketParams memory usdcLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(usdc),
            collateralToken: address(token),
            oracle: address(adapterUsdcLoan),
            irm: irm,
            lltv: LLTV
        });

        bytes32 assetMarket = registry.createAndRegisterMarket(assetLoan);
        bytes32 usdcMarket = registry.createAndRegisterMarket(usdcLoan);

        FxReceipt receiptAsset = new FxReceipt(
            IERC20(address(token)),
            string.concat("fx", asset.symbol, " Tenderly supply receipt"),
            string.concat("fx", asset.symbol, "T"),
            address(morpho),
            _toMorpho(assetLoan)
        );
        FxReceipt receiptUsdc = new FxReceipt(
            IERC20(address(usdc)),
            string.concat("fxUSDC-", asset.symbol, " Tenderly supply receipt"),
            string.concat("fxUSDC-", asset.symbol, "T"),
            address(morpho),
            _toMorpho(usdcLoan)
        );

        FxSwapHook hook = _deployHook(
            poolManagerAddr,
            address(oracle),
            address(registry),
            deployer,
            address(usdc),
            address(token),
            address(morpho)
        );
        _initializePool(poolManagerAddr, address(usdc), address(token), address(hook));
        _seedHook(usdc, token, asset.seedAsset, deployer, hook);

        vm.stopBroadcast();

        string memory root = string.concat("phase2-", asset.symbol);
        vm.serializeAddress(root, string.concat("token_", asset.symbol), address(token));
        vm.serializeAddress(root, string.concat("adapter_", asset.symbol, "_assetLoan"), address(adapterAssetLoan));
        vm.serializeAddress(root, string.concat("adapter_", asset.symbol, "_usdcLoan"), address(adapterUsdcLoan));
        vm.serializeAddress(root, string.concat("receipt_", asset.symbol, "_asset"), address(receiptAsset));
        vm.serializeAddress(root, string.concat("receipt_", asset.symbol, "_usdc"), address(receiptUsdc));
        vm.serializeAddress(root, string.concat("hook_", asset.symbol), address(hook));
        vm.serializeBytes32(root, string.concat("market_", asset.symbol, "_assetLoan"), assetMarket);
        vm.serializeBytes32(root, string.concat("market_", asset.symbol, "_usdcLoan"), usdcMarket);
        vm.serializeBytes32(root, string.concat("feed_", asset.symbol), asset.pythFeed);
        vm.serializeBool(root, string.concat("pythInverted_", asset.symbol), asset.pythInverted);
        string memory json =
            vm.serializeUint(root, string.concat("seedAsset_", asset.symbol), asset.seedAsset);

        vm.writeJson(json, _phaseSubManifestPath(string.concat("phase2-", asset.symbol)));

        console2.log("Phase2 done for", asset.symbol);
        console2.log("  token", address(token));
        console2.log("  hook", address(hook));
    }
}
