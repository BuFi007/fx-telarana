// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxOrderSettlement {
    struct SignedOrder {
        address trader;
        bytes32 marketId;
        int256 sizeDeltaE18;
        uint256 priceE18;
        uint256 maxFee;
        uint8 orderType;
        uint8 flags;
        uint64 nonce;
        uint64 deadline;
    }

    function settleMatch(
        SignedOrder calldata maker,
        bytes calldata makerSig,
        SignedOrder calldata taker,
        bytes calldata takerSig,
        uint256 fillSizeE18,
        uint256 fillPriceE18
    ) external;
    function cancelOrder(uint64 nonce) external;
    function nonceBitmap(address trader, uint256 wordPos) external view returns (uint256);
}
