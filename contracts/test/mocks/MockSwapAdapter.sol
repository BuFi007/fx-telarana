// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFxRouterSwapAdapter} from "../../src/hub/FxRouter.sol";

/// @notice Deterministic mock for `IFxRouterSwapAdapter` used by FxRouter tests.
/// @dev    Returns `(sellAmountNet * rateBps) / 10_000` of `buyToken` to
///         `recipient`. The adapter must be pre-funded with `buyToken` by the
///         test fixture so it can actually deliver. Lets us assert end-to-end
///         token movement without bringing up a full Uniswap v4 PoolManager.
contract MockSwapAdapter is IFxRouterSwapAdapter {
    using SafeERC20 for IERC20;

    /// @notice Sell→buy rate in 1e4 bps. 10_000 = 1:1.
    uint256 public rateBps = 10_000;

    /// @notice If non-zero, force the adapter to deliver this many buyToken
    ///         regardless of sellAmount — used to drive `InsufficientOutput`
    ///         + `AdapterReturnedZero` edge cases.
    uint256 public forcedBuyAmount;
    bool    public forcedSet;

    function setRateBps(uint256 newRate) external { rateBps = newRate; }

    function setForcedBuyAmount(uint256 amount) external {
        forcedBuyAmount = amount;
        forcedSet = true;
    }

    function clearForced() external {
        forcedBuyAmount = 0;
        forcedSet = false;
    }

    function swapExactInput(
        address sellToken,
        address buyToken,
        uint256 sellAmountNet,
        uint256 /*minBuyAmount*/,
        address recipient
    ) external override returns (uint256 buyAmount) {
        // sink the sellToken so the adapter looks real
        sellToken;
        if (forcedSet) {
            buyAmount = forcedBuyAmount;
        } else {
            buyAmount = (sellAmountNet * rateBps) / 10_000;
        }
        if (buyAmount > 0) {
            IERC20(buyToken).safeTransfer(recipient, buyAmount);
        }
    }
}
