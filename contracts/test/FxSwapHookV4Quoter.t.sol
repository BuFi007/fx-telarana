// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {FxSwapHook} from "../src/hub/FxSwapHook.sol";
import {SharedFxVault} from "../src/vault/SharedFxVault.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FxV4RouterHarness} from "./utils/FxV4RouterHarness.sol";

import {MockMorpho, MockOracle} from "./hub/FxSwapHookVaultBacked.t.sol";

/// @notice Local diagnostic for official Uniswap v4 quoter compatibility.
///         FxSwapHook is a custom-accounting PMM hook: input is pulled from
///         PoolManager into SharedFxVault and output is funded back by the vault
///         during beforeSwap. Direct protocol quotes and the protocol router
///         work, but generic empty-hookData V4Quoter should not be claimed.
contract FxSwapHookV4QuoterDiagnosticTest is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    bytes4 internal constant QUOTE_SWAP = bytes4(keccak256("QuoteSwap(uint256)"));

    address internal owner = address(this);
    address internal timelock = makeAddr("timelock");
    address internal trader = makeAddr("trader");

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockMorpho internal morpho;
    MockOracle internal oracle;

    PoolManager internal poolManager;
    FxV4RouterHarness internal router;
    IV4Quoter internal quoter;
    SharedFxVault internal vault;
    FxSwapHook internal hook;
    PoolKey internal key;

    address internal token0;
    address internal token1;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        eurc = new MockERC20("Euro Coin", "EURC", 6);
        morpho = new MockMorpho();
        oracle = new MockOracle();

        (token0, token1) = _sort(address(usdc), address(eurc));

        poolManager = new PoolManager(owner);
        router = new FxV4RouterHarness(IPoolManager(address(poolManager)));
        quoter = new V4Quoter(IPoolManager(address(poolManager)));

        SharedFxVault impl = new SharedFxVault();
        MarketParams memory mkt = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(eurc),
            oracle: address(0xBEEF),
            irm: address(0xCAFE),
            lltv: 0.86e18
        });
        bytes memory initData = abi.encodeCall(
            SharedFxVault.initialize,
            (
                IERC20(address(usdc)),
                owner,
                timelock,
                address(poolManager),
                address(oracle),
                IMorpho(address(morpho)),
                mkt
            )
        );
        vault = SharedFxVault(address(new ERC1967Proxy(address(impl), initData)));

        hook = _deployHook();
        key = _poolKey(address(hook));

        vault.allowHook(address(hook), true);
        vault.grantRole(vault.JUNIOR_ROLE(), address(this));
        _fundJunior(address(usdc), 100_000e6);
        _fundJunior(address(eurc), 100_000e6);

        hook.sync(_juniorOf(token0) * 1e12, _juniorOf(token1) * 1e12, 100);
        poolManager.initialize(key, Q96);
    }

    function test_directQuoteAndProtocolRouterWork() public {
        uint256 amountIn = 1_000e6;
        bool zeroForOne = token0 == address(usdc);
        uint256 directQuote = hook.quote(amountIn, zeroForOne);
        assertGt(directQuote, 0, "direct PMM quote failed");

        usdc.mint(trader, amountIn);
        vm.startPrank(trader);
        usdc.approve(address(router), type(uint256).max);
        uint256 amountOut = router.swapExactInputSingle(key, zeroForOne, amountIn, 1, trader);
        vm.stopPrank();

        assertGt(amountOut, 0, "protocol router produced no output");
        assertEq(eurc.balanceOf(trader), amountOut, "router did not deliver output");
    }

    function test_officialV4QuoterExactInputIsNotGenericForFxSwapHook() public {
        uint256 amountIn = 1_000e6;
        bool zeroForOne = token0 == address(usdc);
        uint256 directQuote = hook.quote(amountIn, zeroForOne);
        assertGt(directQuote, 0, "direct PMM quote failed");

        try quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: uint128(amountIn),
                hookData: ""
            })
        ) returns (uint256, uint256) {
            assertTrue(false, "official V4Quoter unexpectedly produced a generic FxSwapHook quote");
        } catch (bytes memory reason) {
            _assertNotQuoteSwap(reason);
        }
    }

    function test_officialV4QuoterExactOutputIsIntentionallyUnsupported() public {
        bool zeroForOne = token0 == address(usdc);

        try quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: uint128(1_000e6),
                hookData: ""
            })
        ) returns (uint256, uint256) {
            assertTrue(false, "official V4Quoter unexpectedly produced an exact-output FxSwapHook quote");
        } catch (bytes memory reason) {
            _assertNotQuoteSwap(reason);
        }
    }

    function _deployHook() internal returns (FxSwapHook deployed) {
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode,
            abi.encode(
                address(poolManager),
                address(oracle),
                address(0x3333),
                owner,
                token0,
                token1,
                address(morpho),
                address(vault)
            )
        );
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, 500_000);
        deployed = new FxSwapHook{salt: salt}(
            address(poolManager),
            address(oracle),
            address(0x3333),
            owner,
            token0,
            token1,
            address(morpho),
            address(vault)
        );
        require(address(deployed) == expected, "hook addr mismatch");
    }

    function _poolKey(address hookAddress) internal view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
    }

    function _fundJunior(address token, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).approve(address(vault), amount);
        vault.fundJunior(address(hook), token, amount);
    }

    function _juniorOf(address token) internal view returns (uint256) {
        return token == address(usdc)
            ? vault.juniorUsdcOf(address(hook))
            : vault.juniorTokenBalanceOf(address(hook), token);
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function _assertNotQuoteSwap(bytes memory reason) internal pure {
        require(reason.length >= 4, "empty quoter failure");
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 32))
        }
        require(selector != QUOTE_SWAP, "quoter returned a parseable QuoteSwap");
    }
}
