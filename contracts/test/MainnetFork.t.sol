// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, MarketParams as MorphoMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {FxOracle} from "../src/hub/FxOracle.sol";
import {FxMarketRegistry} from "../src/hub/FxMarketRegistry.sol";
import {FxReceipt} from "../src/hub/FxReceipt.sol";
import {FxLiquidator} from "../src/hub/FxLiquidator.sol";
import {MorphoOracleAdapter} from "../src/hub/MorphoOracleAdapter.sol";
import {IFxMarketRegistry} from "../src/interfaces/IFxMarketRegistry.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice Fork-test the FxMarketRegistry + FxReceipt + FxLiquidator stack against
///         the real Morpho Blue deployment on Ethereum mainnet. Skipped unless
///         `ETH_RPC_URL` env var is set.
contract MainnetForkTest is Test {
    using MarketParamsLib for MorphoMarketParams;

    // Ethereum mainnet (chainId 1)
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant EURC = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;

    // 86% LLTV is in widespread mainnet use → already enabled by Morpho governance
    uint256 constant LLTV = 0.86e18;

    bytes32 constant PYTH_USDC_USD = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant PYTH_EURC_USD = 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c;

    IMorpho internal morpho;
    FxOracle internal fxOracle;
    MockPyth internal pyth;
    FxMarketRegistry internal registry;
    MorphoOracleAdapter internal adapterM1;  // loan=EURC, collat=USDC
    MorphoOracleAdapter internal adapterM2;  // loan=USDC, collat=EURC
    FxReceipt internal fxUSDC;
    FxReceipt internal fxEURC;
    FxLiquidator internal liquidator;

    address internal owner = address(0xA11CE);
    address internal lender = address(0xBABE);
    address internal borrower = address(0xCAFE);

    bool internal forkActive;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            return;
        }
        vm.createSelectFork(rpc);
        forkActive = true;

        morpho = IMorpho(MORPHO);

        // Deploy FxOracle with mock Pyth (we control prices in tests; real Pyth feed
        // ids are pre-wired for the deployment scripts).
        pyth = new MockPyth();
        fxOracle = new FxOracle(address(pyth), owner, 600, 100, 100);
        vm.startPrank(owner);
        fxOracle.setFeed(USDC, PYTH_USDC_USD);
        fxOracle.setFeed(EURC, PYTH_EURC_USD);
        vm.stopPrank();

        pyth.setPrice(PYTH_USDC_USD, 1_00_000_000, 100, -8, block.timestamp);
        pyth.setPrice(PYTH_EURC_USD, 1_08_000_000, 100, -8, block.timestamp);

        adapterM1 = new MorphoOracleAdapter(address(fxOracle), EURC, USDC);
        adapterM2 = new MorphoOracleAdapter(address(fxOracle), USDC, EURC);

        registry = new FxMarketRegistry(MORPHO, owner);

        // Ensure LLTV is enabled on Morpho. 0.86e18 is typically enabled mainnet;
        // if not, prank Morpho owner to enable it.
        if (!morpho.isLltvEnabled(LLTV)) {
            address morphoOwner = morpho.owner();
            vm.prank(morphoOwner);
            morpho.enableLltv(LLTV);
        }
        if (!morpho.isIrmEnabled(ADAPTIVE_IRM)) {
            address morphoOwner = morpho.owner();
            vm.prank(morphoOwner);
            morpho.enableIrm(ADAPTIVE_IRM);
        }

        // M1: loan=EURC, collateral=USDC
        IFxMarketRegistry.MarketParams memory m1 = IFxMarketRegistry.MarketParams({
            loanToken: EURC,
            collateralToken: USDC,
            oracle: address(adapterM1),
            irm: ADAPTIVE_IRM,
            lltv: LLTV
        });
        vm.prank(owner);
        registry.createAndRegisterMarket(m1);

        // M2: loan=USDC, collateral=EURC
        IFxMarketRegistry.MarketParams memory m2 = IFxMarketRegistry.MarketParams({
            loanToken: USDC,
            collateralToken: EURC,
            oracle: address(adapterM2),
            irm: ADAPTIVE_IRM,
            lltv: LLTV
        });
        vm.prank(owner);
        registry.createAndRegisterMarket(m2);

        fxUSDC = new FxReceipt(
            IERC20(USDC),
            "fxUSDC supply receipt",
            "fxUSDC",
            MORPHO,
            MorphoMarketParams({loanToken: USDC, collateralToken: EURC, oracle: address(adapterM2), irm: ADAPTIVE_IRM, lltv: LLTV})
        );
        fxEURC = new FxReceipt(
            IERC20(EURC),
            "fxEURC supply receipt",
            "fxEURC",
            MORPHO,
            MorphoMarketParams({loanToken: EURC, collateralToken: USDC, oracle: address(adapterM1), irm: ADAPTIVE_IRM, lltv: LLTV})
        );

        liquidator = new FxLiquidator(MORPHO, address(registry), address(fxOracle));

        // Fund test users via Foundry's `deal` cheatcode
        deal(USDC, lender, 1_000_000e6);
        deal(EURC, lender, 1_000_000e6);
        deal(USDC, borrower, 1_000_000e6);
        deal(EURC, borrower, 1_000_000e6);
    }

    modifier whenFork() {
        if (!forkActive) {
            console_log("ETH_RPC_URL not set; skipping fork test");
            return;
        }
        _;
    }

    function console_log(string memory s) internal pure {
        s; // forge-std console import would inflate compile; this is a no-op gate marker
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fork_registry_routesSupply() public whenFork {
        // Lender supplies 100,000 USDC into M2
        vm.startPrank(lender);
        IERC20(USDC).approve(address(registry), type(uint256).max);
        uint256 shares = registry.supply(USDC, EURC, 100_000e6, lender);
        vm.stopPrank();

        assertGt(shares, 0, "supply minted no shares");
    }

    function test_fork_borrow_againstCollateral() public whenFork {
        // Lender supplies 100k USDC into M2 (loan side)
        vm.startPrank(lender);
        IERC20(USDC).approve(address(registry), type(uint256).max);
        registry.supply(USDC, EURC, 100_000e6, lender);
        vm.stopPrank();

        // Borrower deposits 50k EURC as collateral in M2 and borrows 30k USDC
        vm.startPrank(borrower);
        IERC20(EURC).approve(address(registry), type(uint256).max);
        registry.supplyCollateral(USDC, EURC, 50_000e6, borrower);

        // Authorize registry so it can borrow on borrower's behalf
        morpho.setAuthorization(address(registry), true);

        registry.borrow(USDC, EURC, 30_000e6, borrower, borrower);
        vm.stopPrank();

        // Borrower now has +30k USDC + remaining EURC
        assertGe(IERC20(USDC).balanceOf(borrower), 1_030_000e6 - 1);
    }

    function test_fork_fxReceipt_depositAndWithdraw() public whenFork {
        vm.startPrank(lender);
        IERC20(USDC).approve(address(fxUSDC), type(uint256).max);

        uint256 shares = fxUSDC.deposit(100_000e6, lender);
        assertGt(shares, 0);

        // Roll time so interest may accrue (here utilization is 0; assets ~ unchanged)
        skip(7 days);

        uint256 assetsOut = fxUSDC.redeem(shares, lender, lender);
        vm.stopPrank();

        // Without borrowing, no interest accrues — receipt should return ~ deposit
        assertApproxEqAbs(assetsOut, 100_000e6, 10);
    }

    function test_fork_marketIds_deterministic() public whenFork {
        bytes32 m1id = registry.marketIdOf(EURC, USDC);
        bytes32 m2id = registry.marketIdOf(USDC, EURC);
        assertTrue(m1id != bytes32(0));
        assertTrue(m2id != bytes32(0));
        assertTrue(m1id != m2id);

        IFxMarketRegistry.MarketParams memory p = registry.paramsOf(EURC, USDC);
        assertEq(p.loanToken, EURC);
        assertEq(p.collateralToken, USDC);
    }
}
