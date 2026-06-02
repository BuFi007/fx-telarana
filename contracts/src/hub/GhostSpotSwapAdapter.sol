// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IGhostRouterSwapAdapter {
    function swapExactInput(
        address sellToken,
        address buyToken,
        uint256 sellAmountNet,
        uint256 minBuyAmount,
        address recipient
    ) external returns (uint256 buyAmount);
}

/// @title GhostSpotSwapAdapter
/// @notice Minimal execution adapter for FxPrivacyEntrypoint.relayExecute spot
///         swaps. The privacy entrypoint transfers the shielded sell asset here,
///         then calls execute(); this adapter forwards the input to the existing
///         router swap adapter and asks it to settle output back to the
///         entrypoint, where relayExecute measures and forwards to the private
///         recipient.
contract GhostSpotSwapAdapter {
    address public immutable SWAP;
    address public immutable ENTRYPOINT;

    error ZeroAddress();
    error OnlyEntrypoint();
    error BuyTokenEqualsSell();
    error TransferFailed(address token, address to, uint256 amount);

    constructor(address swap_, address entrypoint_) {
        if (swap_ == address(0) || entrypoint_ == address(0)) revert ZeroAddress();
        SWAP = swap_;
        ENTRYPOINT = entrypoint_;
    }

    function execute(address asset, uint256 amount, address, bytes calldata data)
        external
        returns (address resultToken, uint256 resultAmount)
    {
        if (msg.sender != ENTRYPOINT) revert OnlyEntrypoint();
        (address buyToken, uint256 minBuyAmount) = abi.decode(data, (address, uint256));
        if (buyToken == asset) revert BuyTokenEqualsSell();

        _safeTransfer(asset, SWAP, amount);
        uint256 out = IGhostRouterSwapAdapter(SWAP).swapExactInput(
            asset,
            buyToken,
            amount,
            minBuyAmount,
            ENTRYPOINT
        );
        return (buyToken, out);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed(token, to, amount);
        }
    }
}
