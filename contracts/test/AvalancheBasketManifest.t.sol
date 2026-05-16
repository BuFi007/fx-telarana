// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";

import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {FxV4RouterHarness} from "./utils/FxV4RouterHarness.sol";

/// @notice Address-based Tenderly vnet drill. Unlike AvalancheBasketSmokeTest,
///         this attaches to already-deployed contracts from a persisted
///         manifest and exercises the live vnet stack.
contract AvalancheBasketManifestTest is Test {
    uint256 internal constant LLTV = 0.86e18;

    bytes32 constant FEED_USDC = keccak256("USDC");
    bytes32 constant FEED_AUDF = keccak256("AUDF");
    bytes32 constant FEED_JPYC = keccak256("JPYC");
    bytes32 constant FEED_MXNB = keccak256("MXNB");
    bytes32 constant FEED_KRW1 = keccak256("KRW1");
    bytes32 constant FEED_ZCHF = keccak256("ZCHF");

    string internal manifestPath;
    string internal manifestJson;

    address internal deployer;
    MockStablecoin internal usdc;
    MockPyth internal pyth;
    FxMarketRegistry internal registry;
    IMorpho internal morpho;
    address internal poolManager;
    FxV4RouterHarness internal swapRouter;

    address internal trader = address(0xCAFE);

    struct AssetCase {
        string symbol;
        address token;
        address hook;
        bytes32 feed;
        int64 pythPrice;
        uint256 seedAsset;
    }

    function setUp() public {
        manifestPath = vm.envOr("FXT_BASKET_MANIFEST", string("../deployments/tenderly-avalanche-fuji-basket.json"));
        if (!vm.isFile(manifestPath)) {
            vm.skip(true, "Tenderly basket manifest missing");
        }
        if (block.chainid != 43113) {
            vm.skip(true, "Tenderly basket manifest drill requires Fuji chainId");
        }

        manifestJson = vm.readFile(manifestPath);
        deployer = vm.parseJsonAddress(manifestJson, ".deployer");
        usdc = MockStablecoin(vm.parseJsonAddress(manifestJson, ".USDC"));
        pyth = MockPyth(vm.parseJsonAddress(manifestJson, ".MockPyth"));
        registry = FxMarketRegistry(vm.parseJsonAddress(manifestJson, ".FxMarketRegistry"));
        morpho = IMorpho(vm.parseJsonAddress(manifestJson, ".MorphoBlue"));
        poolManager = vm.parseJsonAddress(manifestJson, ".PoolManager");
        swapRouter = new FxV4RouterHarness(IPoolManager(poolManager));

        _refreshPrices();
    }

    function test_manifestAddressesAndSeededHooks() public view {
        assertEq(block.chainid, 43113, "wrong chain");
        _assertHasCode(address(usdc), "USDC");
        _assertHasCode(address(pyth), "MockPyth");
        _assertHasCode(address(registry), "FxMarketRegistry");
        _assertHasCode(address(morpho), "MorphoBlue");
        _assertHasCode(poolManager, "PoolManager");
        _assertHasCode(address(swapRouter), "FxV4RouterHarness");

        IFxMarketRegistry.MarketParams[] memory pools = registry.listPools();
        assertEq(pools.length, 10, "basket should register two markets per asset");

        AssetCase[] memory cases = _basketCases();
        for (uint256 i; i < cases.length; ++i) {
            AssetCase memory c = cases[i];
            _assertHasCode(c.token, string.concat(c.symbol, " token"));
            _assertHasCode(c.hook, string.concat(c.symbol, " hook"));
            assertTrue(registry.isPoolLive(c.token, address(usdc)), string.concat(c.symbol, " asset market not live"));
            assertTrue(registry.isPoolLive(address(usdc), c.token), string.concat(c.symbol, " USDC market not live"));
            assertGt(FxSwapHook(c.hook).morphoShares(address(usdc)), 0, string.concat(c.symbol, " no USDC shares"));
            assertGt(FxSwapHook(c.hook).morphoShares(c.token), 0, string.concat(c.symbol, " no asset shares"));
        }
    }

    function test_manifestSwapMatrix() public {
        AssetCase[] memory cases = _basketCases();
        for (uint256 i; i < cases.length; ++i) {
            _exerciseSwap(cases[i]);
        }
    }

    function test_manifestLendBorrowRepayWithdrawMatrix() public {
        AssetCase[] memory cases = _basketCases();
        for (uint256 i; i < cases.length; ++i) {
            _runLendBorrowCase(cases[i]);
        }
    }

    function _basketCases() internal view returns (AssetCase[] memory cases) {
        cases = new AssetCase[](5);
        cases[0] = _case("JPYC", FEED_JPYC, 156_25_000_000, 1_562_500e18);
        cases[1] = _case("MXNB", FEED_MXNB, 1_726_300_000, 172_630e6);
        cases[2] = _case("AUDF", FEED_AUDF, 71_909_500, 13_906e6);
        cases[3] = _case("KRW1", FEED_KRW1, 148_986_889_100, 14_898_689);
        cases[4] = _case("ZCHF", FEED_ZCHF, 78_500_000, 7_850e18);
    }

    function _case(string memory symbol, bytes32 feed, int64 pythPrice, uint256 seedAsset)
        internal
        view
        returns (AssetCase memory c)
    {
        c = AssetCase({
            symbol: symbol,
            token: vm.parseJsonAddress(manifestJson, string.concat(".token_", symbol)),
            hook: vm.parseJsonAddress(manifestJson, string.concat(".hook_", symbol)),
            feed: feed,
            pythPrice: pythPrice,
            seedAsset: seedAsset
        });
    }

    function _refreshPrices() internal {
        pyth.setPrice(FEED_USDC, 1_00_000_000, 100, -8, block.timestamp);
        pyth.setPrice(FEED_JPYC, 156_25_000_000, 100, -8, block.timestamp);
        pyth.setPrice(FEED_MXNB, 1_726_300_000, 100, -8, block.timestamp);
        pyth.setPrice(FEED_AUDF, 71_909_500, 100, -8, block.timestamp);
        pyth.setPrice(FEED_KRW1, 148_986_889_100, 100, -8, block.timestamp);
        pyth.setPrice(FEED_ZCHF, 78_500_000, 100, -8, block.timestamp);
    }

    function _exerciseSwap(AssetCase memory c) internal {
        MockStablecoin asset = MockStablecoin(c.token);
        FxSwapHook hook = FxSwapHook(c.hook);
        PoolKey memory key = _poolKey(c.token, c.hook);
        uint256 amountIn = 100e6;

        (uint256 quoted,) = hook.quoteExactInput(address(usdc), amountIn);
        assertGt(quoted, 0, string.concat(c.symbol, " quote missing"));

        vm.startPrank(deployer);
        usdc.mint(trader, amountIn);
        vm.stopPrank();

        uint256 assetBefore = asset.balanceOf(trader);
        vm.startPrank(trader);
        usdc.approve(address(swapRouter), type(uint256).max);
        uint256 amountOut = swapRouter.swapExactInputSingle(
            key, Currency.unwrap(key.currency0) == address(usdc), amountIn, quoted, trader
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(trader), 0, string.concat(c.symbol, " input not consumed"));
        assertEq(asset.balanceOf(trader) - assetBefore, amountOut, string.concat(c.symbol, " output mismatch"));
        assertGe(amountOut, quoted, string.concat(c.symbol, " output below quote"));
        assertEq(usdc.balanceOf(poolManager), 0, string.concat(c.symbol, " manager kept USDC"));
        assertEq(asset.balanceOf(poolManager), 0, string.concat(c.symbol, " manager kept asset"));
    }

    function _runLendBorrowCase(AssetCase memory c) internal {
        MockStablecoin asset = MockStablecoin(c.token);
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

    function _exerciseLendBorrowMarket(
        string memory label,
        MockStablecoin loanToken,
        MockStablecoin collateralToken,
        uint256 lenderSupply,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal {
        assertGt(lenderSupply, 0, string.concat(label, ": lender supply is zero"));
        assertGt(collateralAmount, 0, string.concat(label, ": collateral is zero"));
        assertGt(borrowAmount, 0, string.concat(label, ": borrow is zero"));

        address lender = address(uint160(uint256(keccak256(bytes(string.concat(label, ":lender"))))));
        address borrower = address(uint160(uint256(keccak256(bytes(string.concat(label, ":borrower"))))));

        vm.startPrank(deployer);
        loanToken.mint(lender, lenderSupply);
        collateralToken.mint(borrower, collateralAmount);
        vm.stopPrank();

        vm.startPrank(lender);
        morpho.setAuthorization(address(registry), true);
        loanToken.approve(address(registry), lenderSupply);
        uint256 supplyShares = registry.supply(address(loanToken), address(collateralToken), lenderSupply, lender);
        vm.stopPrank();
        assertGt(supplyShares, 0, string.concat(label, ": no lender shares"));

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

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function _assertHasCode(address target, string memory label) internal view {
        assertGt(target.code.length, 0, string.concat(label, " has no code"));
    }
}
