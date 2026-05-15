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

import {FxOracle} from "../../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../../src/hub/FxReceipt.sol";
import {FxLiquidator} from "../../src/hub/FxLiquidator.sol";
import {FxSwapHook} from "../../src/hub/FxSwapHook.sol";
import {MorphoOracleAdapter} from "../../src/hub/MorphoOracleAdapter.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {IFxMarketRegistry} from "../../src/interfaces/IFxMarketRegistry.sol";
import {MockStablecoin} from "../../src/test-helpers/MockStablecoin.sol";
import {MockPyth} from "../../test/mocks/MockPyth.sol";

/// @notice Shared deploy helpers for the Tenderly Avalanche basket drill,
///         split into discrete phase scripts to fit under Tenderly Pro
///         per-second TUs ceiling. Each phase script extends this base and
///         emits a sub-manifest at `deployments/_tenderly-basket-phases/<phase>.json`.
///         A bash driver merges all sub-manifests into the canonical
///         `deployments/tenderly-avalanche-fuji-basket.json` after Phase 3.
///
/// Composition discipline: this contract holds zero balances, has no
/// external balance-handling logic. It only sequences deploys + writes
/// JSON. Per-phase scripts inherit this and drive `vm.startBroadcast`.
abstract contract BasketDeployBase is Script {
    using SafeERC20 for IERC20;

    address internal constant HOOK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint256 internal constant LLTV = 0.86e18;

    address internal constant DEFAULT_FUJI_MORPHO = 0xeF64621D41093144D9ED8aB8327eE381ECdB79E6;
    address internal constant DEFAULT_FUJI_IRM = 0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA;
    address internal constant DEFAULT_FUJI_CCTP_MT = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;

    bytes32 internal constant FEED_USDC = keccak256("USDC");
    bytes32 internal constant FEED_AUDF = keccak256("AUDF");
    bytes32 internal constant FEED_JPYC = keccak256("JPYC");
    bytes32 internal constant FEED_MXNB = keccak256("MXNB");
    bytes32 internal constant FEED_KRW1 = keccak256("KRW1");
    bytes32 internal constant FEED_ZCHF = keccak256("ZCHF");

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

    function _assetFor(string memory symbol) internal pure returns (AssetConfig memory) {
        bytes32 s = keccak256(bytes(symbol));
        if (s == keccak256("JPYC")) {
            return AssetConfig("JPYC", "Tenderly JPYC", 18, FEED_JPYC, true, bytes32("JPY"), 156_25_000_000, 1_562_500e18);
        }
        if (s == keccak256("MXNB")) {
            return AssetConfig("MXNB", "Tenderly MXNB", 6, FEED_MXNB, true, bytes32("MXN"), 1_726_300_000, 172_630e6);
        }
        if (s == keccak256("AUDF")) {
            return AssetConfig("AUDF", "Tenderly AUDF", 6, FEED_AUDF, false, bytes32("AUD"), 71_909_500, 13_906e6);
        }
        if (s == keccak256("KRW1")) {
            return AssetConfig("KRW1", "Tenderly KRW1", 0, FEED_KRW1, true, bytes32("KRW"), 148_986_889_100, 14_898_689);
        }
        if (s == keccak256("ZCHF")) {
            return AssetConfig("ZCHF", "Tenderly ZCHF", 18, FEED_ZCHF, true, bytes32("CHF"), 78_500_000, 7_850e18);
        }
        revert("BasketDeployBase: unknown asset symbol (allowed: JPYC,MXNB,AUDF,KRW1,ZCHF)");
    }

    function _deployToken(string memory name, string memory symbol, uint8 decimals_, address owner)
        internal
        returns (MockStablecoin token)
    {
        token = new MockStablecoin(name, symbol, decimals_, owner);
        token.setFaucetOpen(true);
    }

    function _setPrice(MockPyth pyth, bytes32 feed, int64 price) internal {
        pyth.setPrice(feed, price, 100, -8, block.timestamp);
    }

    function _deployHook(
        address poolManager,
        address oracle,
        address registry,
        address admin,
        address usdc,
        address assetToken,
        address morpho
    ) internal returns (FxSwapHook hook) {
        (address token0, address token1) = _sort(usdc, assetToken);
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(poolManager, oracle, registry, admin, token0, token1, morpho)
        );
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(HOOK_CREATE2_FACTORY, flags, creationCode, 500_000);
        (bool ok, bytes memory ret) = HOOK_CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode));
        require(ok, "BasketDeployBase: hook CREATE2 failed");
        address actual;
        assembly {
            actual := mload(add(ret, 20))
        }
        require(actual == expected, "BasketDeployBase: hook address mismatch");
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

    function _seedHook(MockStablecoin usdc, MockStablecoin asset, uint256 assetAmount, address deployer, FxSwapHook hook)
        internal
    {
        uint256 usdcAmount = 10_000e6;
        usdc.mint(deployer, usdcAmount);
        asset.mint(deployer, assetAmount);
        IERC20(address(usdc)).forceApprove(address(hook), usdcAmount);
        IERC20(address(asset)).forceApprove(address(hook), assetAmount);
        if (hook.TOKEN0() == address(usdc)) {
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

    /// @notice Read an address key from the canonical basket manifest. Phase 2+
    ///         scripts call this to look up Phase 1's deployments.
    function _readManifestAddress(string memory key) internal view returns (address) {
        string memory raw = vm.readFile(_manifestPath());
        return vm.parseJsonAddress(raw, string.concat(".", key));
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr("FXT_BASKET_MANIFEST", string("./deployments/tenderly-avalanche-fuji-basket.json"));
    }

    function _phaseSubManifestPath(string memory phaseSlug) internal view returns (string memory) {
        return string.concat(
            vm.envOr("FXT_BASKET_PHASES_DIR", string("./deployments/_tenderly-basket-phases")),
            "/",
            phaseSlug,
            ".json"
        );
    }
}
