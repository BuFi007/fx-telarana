// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {FxV4RouterHarness} from "./utils/FxV4RouterHarness.sol";

/// @notice Avalanche-shaped basket smoke drill. This is the local/Tenderly-vnet
///         rehearsal for deploying basket markets, seeding hook liquidity, and
///         executing exact-input v4 swaps for every Phase 3 USDC pair.
contract AvalancheBasketSmokeTest is Test {
    uint256 internal constant LLTV = 0.86e18;
    uint160 internal constant Q96 = 79228162514264337593543950336;

    MockERC20 internal usdc;
    MockPyth internal pyth;
    FxOracle internal oracle;
    FxMarketRegistry internal registry;
    IMorpho internal morpho;
    address internal irm;
    PoolManager internal poolManager;
    FxV4RouterHarness internal swapRouter;

    address internal owner = address(this);
    address internal lp = address(0xBEEF);
    address internal trader = address(0xCAFE);

    struct AssetCase {
        string symbol;
        uint8 decimals_;
        int64 pythPrice;
        bool pythInverted;
        uint256 seedAsset;
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pyth = new MockPyth();
        oracle = new FxOracle(address(pyth), owner, 600, 100, 100);
        registry = new FxMarketRegistry(address(0x1234), owner);
        poolManager = new PoolManager(owner);
        swapRouter = new FxV4RouterHarness(IPoolManager(address(poolManager)));

        if (
            !vm.isFile("out/Morpho.sol/Morpho.json") || !vm.isFile("out/IrmMock.sol/IrmMock.json")
                || bytes(_fxSwapHookArtifact()).length == 0
        ) {
            vm.skip(true, "run forge build --force test/MorphoArtifacts.t.sol before basket smoke");
        }

        morpho = IMorpho(deployCode("out/Morpho.sol/Morpho.json", abi.encode(owner)));
        irm = deployCode("out/IrmMock.sol/IrmMock.json");
        morpho.enableIrm(irm);
        morpho.enableLltv(LLTV);

        registry = new FxMarketRegistry(address(morpho), owner);

        oracle.setPythFeedConfig(address(usdc), _feed("USDC"), false);
        pyth.setPrice(_feed("USDC"), 1_00_000_000, 100, -8, block.timestamp);
    }

    function test_basketDeploySeedAndSwapMatrix() public {
        AssetCase[] memory cases = _basketCases();

        for (uint256 i; i < cases.length; ++i) {
            _runCase(cases[i]);
        }
    }

    function test_basketLendBorrowRepayWithdrawMatrix() public {
        AssetCase[] memory cases = _basketCases();

        for (uint256 i; i < cases.length; ++i) {
            _runLendBorrowCase(cases[i]);
        }
    }

    function _basketCases() internal pure returns (AssetCase[] memory cases) {
        cases = new AssetCase[](5);
        cases[0] = AssetCase("JPYC", 18, 156_25_000_000, true, 1_562_500e18);
        cases[1] = AssetCase("MXNB", 6, 1_726_300_000, true, 172_630e6);
        cases[2] = AssetCase("AUDF", 6, 71_909_500, false, 13_906e6);
        cases[3] = AssetCase("KRW1", 0, 148_986_889_100, true, 14_898_689);
        cases[4] = AssetCase("ZCHF", 18, 78_500_000, true, 7_850e18);
    }

    function _runCase(AssetCase memory c) internal {
        MockERC20 asset = _deployAssetAndMarkets(c);

        FxSwapHook hook = _deployHook(address(asset));
        PoolKey memory key = _poolKey(address(asset), address(hook));
        poolManager.initialize(key, Q96);

        // First deposit is owner-gated (codex-r12). Owner = this test contract.
        usdc.mint(owner, 10_000e6);
        asset.mint(owner, c.seedAsset);
        usdc.approve(address(hook), type(uint256).max);
        asset.approve(address(hook), type(uint256).max);
        _depositSorted(hook, address(usdc), 10_000e6, address(asset), c.seedAsset);

        assertGt(hook.morphoShares(address(usdc)), 0, "USDC was not rehypothecated");
        assertGt(hook.morphoShares(address(asset)), 0, "asset was not rehypothecated");

        uint256 amountIn = 100e6;
        (uint256 quoted,) = hook.quoteExactInput(address(usdc), amountIn);
        assertGt(quoted, 0, string.concat(c.symbol, " quote missing"));

        usdc.mint(trader, amountIn);
        uint256 assetBefore = asset.balanceOf(trader);
        vm.startPrank(trader);
        usdc.approve(address(swapRouter), type(uint256).max);
        uint256 amountOut = swapRouter.swapExactInputSingle(
            key, Currency.unwrap(key.currency0) == address(usdc), amountIn, quoted, trader
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(trader), 0, "USDC exact input not consumed");
        assertEq(asset.balanceOf(trader) - assetBefore, amountOut, string.concat(c.symbol, " output mismatch"));
        assertGe(amountOut, quoted, string.concat(c.symbol, " output below quote"));
        assertEq(usdc.balanceOf(address(poolManager)), 0, string.concat(c.symbol, " manager kept USDC"));
        assertEq(asset.balanceOf(address(poolManager)), 0, string.concat(c.symbol, " manager kept asset"));
    }

    function _runLendBorrowCase(AssetCase memory c) internal {
        MockERC20 asset = _deployAssetAndMarkets(c);

        uint256 assetSupply = c.seedAsset / 10;
        uint256 assetBorrow = c.seedAsset / 100;
        uint256 assetCollateral = c.seedAsset / 10;

        _exerciseLendBorrowMarket({
            label: string.concat(c.symbol, "-loan/USDC-collateral"),
            loanToken: asset,
            collateralToken: usdc,
            lenderSupply: assetSupply,
            collateralAmount: 1_000e6,
            borrowAmount: assetBorrow
        });

        _exerciseLendBorrowMarket({
            label: string.concat("USDC-loan/", c.symbol, "-collateral"),
            loanToken: usdc,
            collateralToken: asset,
            lenderSupply: 10_000e6,
            collateralAmount: assetCollateral,
            borrowAmount: 100e6
        });
    }

    function _deployAssetAndMarkets(AssetCase memory c) internal returns (MockERC20 asset) {
        asset = new MockERC20(c.symbol, c.symbol, c.decimals_);
        bytes32 feed = _feed(c.symbol);
        oracle.setPythFeedConfig(address(asset), feed, c.pythInverted);
        pyth.setPrice(feed, c.pythPrice, 100, -8, block.timestamp);

        MorphoOracleAdapter adapterAssetLoan = new MorphoOracleAdapter(address(oracle), address(asset), address(usdc));
        MorphoOracleAdapter adapterUsdcLoan = new MorphoOracleAdapter(address(oracle), address(usdc), address(asset));

        IFxMarketRegistry.MarketParams memory assetLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(asset),
            collateralToken: address(usdc),
            oracle: address(adapterAssetLoan),
            irm: irm,
            lltv: LLTV
        });
        IFxMarketRegistry.MarketParams memory usdcLoan = IFxMarketRegistry.MarketParams({
            loanToken: address(usdc),
            collateralToken: address(asset),
            oracle: address(adapterUsdcLoan),
            irm: irm,
            lltv: LLTV
        });
        registry.createAndRegisterMarket(assetLoan);
        registry.createAndRegisterMarket(usdcLoan);
    }

    function _exerciseLendBorrowMarket(
        string memory label,
        MockERC20 loanToken,
        MockERC20 collateralToken,
        uint256 lenderSupply,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal {
        assertGt(lenderSupply, 0, string.concat(label, ": lender supply is zero"));
        assertGt(collateralAmount, 0, string.concat(label, ": collateral is zero"));
        assertGt(borrowAmount, 0, string.concat(label, ": borrow is zero"));

        address lender = address(uint160(uint256(keccak256(bytes(string.concat(label, ":lender"))))));
        address borrower = address(uint160(uint256(keccak256(bytes(string.concat(label, ":borrower"))))));

        loanToken.mint(lender, lenderSupply);
        collateralToken.mint(borrower, collateralAmount);

        vm.startPrank(lender);
        morpho.setAuthorization(address(registry), true);
        loanToken.approve(address(registry), lenderSupply);
        uint256 supplyShares = registry.supply(address(loanToken), address(collateralToken), lenderSupply, lender);
        vm.stopPrank();
        assertGt(supplyShares, 0, string.concat(label, ": no lender shares"));
        assertEq(loanToken.balanceOf(lender), 0, string.concat(label, ": lender supply not pulled"));

        vm.startPrank(borrower);
        morpho.setAuthorization(address(registry), true);
        collateralToken.approve(address(registry), collateralAmount);
        registry.supplyCollateral(address(loanToken), address(collateralToken), collateralAmount, borrower);

        uint256 loanBeforeBorrow = loanToken.balanceOf(borrower);
        uint256 borrowedShares =
            registry.borrow(address(loanToken), address(collateralToken), borrowAmount, borrower, borrower);
        assertGt(borrowedShares, 0, string.concat(label, ": no borrow shares"));
        assertEq(
            loanToken.balanceOf(borrower),
            loanBeforeBorrow + borrowAmount,
            string.concat(label, ": borrow output mismatch")
        );

        loanToken.approve(address(registry), borrowAmount);
        uint256 repaidShares = registry.repay(address(loanToken), address(collateralToken), borrowAmount, borrower);
        assertEq(repaidShares, borrowedShares, string.concat(label, ": repay did not clear borrow shares"));

        uint256 collateralBeforeWithdraw = collateralToken.balanceOf(borrower);
        registry.withdrawCollateral(address(loanToken), address(collateralToken), collateralAmount, borrower, borrower);
        assertEq(
            collateralToken.balanceOf(borrower),
            collateralBeforeWithdraw + collateralAmount,
            string.concat(label, ": collateral withdraw mismatch")
        );
        vm.stopPrank();

        uint256 loanBeforeWithdraw = loanToken.balanceOf(lender);
        vm.prank(lender);
        uint256 assetsOut =
            registry.withdraw(address(loanToken), address(collateralToken), supplyShares, lender, lender);
        assertGt(assetsOut, 0, string.concat(label, ": withdraw returned zero"));
        assertEq(
            loanToken.balanceOf(lender),
            loanBeforeWithdraw + assetsOut,
            string.concat(label, ": lender withdraw mismatch")
        );
    }

    function _deployHook(address asset) internal returns (FxSwapHook hook) {
        (address token0, address token1) = _sort(address(usdc), asset);
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(address(poolManager), address(oracle), address(registry), owner, token0, token1, address(morpho), address(0x5555))
        );
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected,) = HookMiner.find(address(this), flags, creationCode, 500_000);
        deployCodeTo(
            _fxSwapHookArtifact(),
            abi.encode(
                address(poolManager), address(oracle), address(registry), owner, token0, token1, address(morpho), address(0x5555)
            ),
            expected
        );
        hook = FxSwapHook(expected);
    }

    function _fxSwapHookArtifact() internal view returns (string memory) {
        if (vm.isFile("out/FxSwapHook.sol/FxSwapHook.json")) return "out/FxSwapHook.sol/FxSwapHook.json";
        if (vm.isFile("out/FxSwapHook.sol/FxSwapHook.0.8.26.json")) return "out/FxSwapHook.sol/FxSwapHook.0.8.26.json";
        if (vm.isFile("out/FxSwapHook.sol/FxSwapHook.0.8.28.json")) return "out/FxSwapHook.sol/FxSwapHook.0.8.28.json";
        return "";
    }

    function _poolKey(address asset, address hook) internal view returns (PoolKey memory key) {
        (address token0, address token1) = _sort(address(usdc), asset);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function _depositSorted(FxSwapHook hook, address tokenA, uint256 amountA, address tokenB, uint256 amountB)
        internal
    {
        if (hook.TOKEN0() == tokenA) {
            hook.deposit(amountA, amountB);
        } else {
            assertEq(hook.TOKEN0(), tokenB);
            hook.deposit(amountB, amountA);
        }
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function _feed(string memory symbol) internal pure returns (bytes32) {
        return keccak256(bytes(symbol));
    }
}
