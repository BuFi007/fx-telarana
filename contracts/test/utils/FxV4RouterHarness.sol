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

/// @notice Minimal exact-input v4 router for custom-accounting hooks.
/// @dev FxSwapHook takes the specified input from PoolManager during
///      `beforeSwap`, so this harness settles the user's input into
///      PoolManager before calling `swap`. This mirrors the required
///      settlement ordering without pre-minting tokens to the manager.
contract FxV4RouterHarness is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    error NotPoolManager(address caller);
    error ZeroAmount();
    error AmountTooLarge(uint256 amount);
    error NonPositiveOutput(int128 outputDelta);
    error TooLittleReceived(uint256 minimum, uint256 received);

    struct ExactInputSingle {
        address sender;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapExactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge(amountIn);

        amountOut = abi.decode(
            manager.unlock(
                abi.encode(
                    ExactInputSingle({
                        sender: msg.sender,
                        key: key,
                        zeroForOne: zeroForOne,
                        amountIn: amountIn,
                        amountOutMinimum: amountOutMinimum,
                        recipient: recipient
                    })
                )
            ),
            (uint256)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager(msg.sender);

        ExactInputSingle memory data = abi.decode(rawData, (ExactInputSingle));
        Currency input = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency output = data.zeroForOne ? data.key.currency1 : data.key.currency0;

        _settleFrom(input, data.sender, data.amountIn);

        BalanceDelta delta = manager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 outputDelta = data.zeroForOne ? delta.amount1() : delta.amount0();
        if (outputDelta <= 0) revert NonPositiveOutput(outputDelta);

        uint256 amountOut = uint128(outputDelta);
        if (amountOut < data.amountOutMinimum) revert TooLittleReceived(data.amountOutMinimum, amountOut);

        manager.take(output, data.recipient, amountOut);
        return abi.encode(amountOut);
    }

    function _settleFrom(Currency currency, address payer, uint256 amount) internal {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
        manager.settle();
    }
}
