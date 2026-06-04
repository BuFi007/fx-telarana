// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Exact-input v4 router that forwards arbitrary `hookData` to the
///         pool's hook (designed for `TelaranaGatewayHubHook.beforeSwap` —
///         Wave N6 / PR-H8 Demo B).
/// @dev Differs from `FxV4RouterHarness` by:
///        1. accepts `bytes hookData` and forwards it verbatim to `manager.swap`.
///        2. tolerates `outputDelta == 0` — the Gateway hub hook supplies
///           the output currency via `BeforeSwapDelta(0, -amountReceived)`,
///           and the standard balance-delta from PoolManager may be zero or
///           negative because the pool itself has no liquidity. The hook's
///           own settlement (POOL_MANAGER.settle() after USDC.transfer) is
///           what actually credits the manager's accounting.
contract FxV4RouterHarnessGateway is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    error NotPoolManager(address caller);
    error ZeroAmount();
    error AmountTooLarge(uint256 amount);
    error TooLittleReceived(uint256 minimum, uint256 received);

    struct ExactInputSingleWithHookData {
        address sender;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Exact-input single-hop swap that forwards `hookData` to the
    ///         hook's `beforeSwap`. The hook is expected to materialise the
    ///         output currency via `BeforeSwapDelta` (e.g. Gateway intra-hook
    ///         liquidity injection).
    function swapExactInputSingleWithHookData(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        bytes calldata hookData
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge(amountIn);

        amountOut = abi.decode(
            manager.unlock(
                abi.encode(
                    ExactInputSingleWithHookData({
                        sender: msg.sender,
                        key: key,
                        zeroForOne: zeroForOne,
                        amountIn: amountIn,
                        amountOutMinimum: amountOutMinimum,
                        recipient: recipient,
                        hookData: hookData
                    })
                )
            ),
            (uint256)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager(msg.sender);

        ExactInputSingleWithHookData memory data = abi.decode(rawData, (ExactInputSingleWithHookData));
        Currency input = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency output = data.zeroForOne ? data.key.currency1 : data.key.currency0;

        // Settle the user's input into PoolManager BEFORE calling swap.
        _settleFrom(input, data.sender, data.amountIn);

        BalanceDelta delta = manager.swap(
            data.key,
            SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            data.hookData
        );

        // With Gateway intra-hook liquidity, the raw pool swap may run
        // against zero liquidity. The hook's BeforeSwapDelta is what
        // credits the caller for the output. If the pool has no LP, the
        // pre-settled input may also still be "owed back" to this router
        // (no LP consumed it).
        //
        // Read accumulated currencyDelta directly from the manager's
        // transient state, then settle any non-zero residuals.
        // Positive delta = manager owes us → call `take` to redeem.
        // Negative delta = we owe manager → call `settle` to pay.
        int256 delta0 = manager.currencyDelta(address(this), data.key.currency0);
        int256 delta1 = manager.currencyDelta(address(this), data.key.currency1);

        uint256 outAmount;
        Currency outputCurrency = data.zeroForOne ? data.key.currency1 : data.key.currency0;
        int256 outputDelta = data.zeroForOne ? delta1 : delta0;
        int256 inputDelta = data.zeroForOne ? delta0 : delta1;
        Currency inputCurrency = data.zeroForOne ? data.key.currency0 : data.key.currency1;

        // Take the output to the recipient.
        if (outputDelta > 0) {
            outAmount = uint256(outputDelta);
            manager.take(outputCurrency, data.recipient, outAmount);
        }

        // The user already paid input via _settleFrom; if the pool didn't
        // consume it (no liquidity), the manager still owes the router back
        // on the input side. Take that residual to the sender (return the
        // user's input).
        if (inputDelta > 0) {
            manager.take(inputCurrency, data.sender, uint256(inputDelta));
        } else if (inputDelta < 0) {
            // Defensive: shouldn't happen for exact-input swaps that already
            // pre-settled, but handle to keep the unlock callback closed.
            uint256 owed = uint256(-inputDelta);
            IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(data.sender, address(manager), owed);
            manager.sync(inputCurrency);
            manager.settle();
        }

        if (outAmount < data.amountOutMinimum) revert TooLittleReceived(data.amountOutMinimum, outAmount);
        return abi.encode(outAmount);
    }

    function _settleFrom(Currency currency, address payer, uint256 amount) internal {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
        manager.settle();
    }
}
