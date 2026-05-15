// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title ITelaranaRfqPasillo
/// @notice Placeholder RFQ corridor interface for future Telarana quote-based FX.
/// @dev Interface-only. No matching engine, market maker registry, settlement,
///      or swap execution is implemented in this branch.
interface ITelaranaRfqPasillo {
    struct RfqQuoteRequest {
        address requester;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        bytes32 routeId;
        address recipient;
        uint256 deadline;
        bytes32 metadataRef;
    }

    struct RfqQuote {
        bytes32 quoteRequestId;
        address maker;
        uint256 amountOut;
        uint256 validUntil;
        address settlementTarget;
        bytes32 metadataRef;
    }

    event RfqQuoteRequested(
        bytes32 indexed quoteRequestId,
        address indexed requester,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes32 routeId,
        address recipient,
        uint256 deadline,
        bytes32 metadataRef
    );

    event RfqQuoteAccepted(
        bytes32 indexed quoteId,
        bytes32 indexed quoteRequestId,
        address indexed requester,
        address maker,
        uint256 amountOut,
        uint256 validUntil,
        address settlementTarget,
        bytes32 metadataRef
    );

    event RfqQuoteFilled(
        bytes32 indexed quoteId,
        bytes32 indexed quoteRequestId,
        address indexed filler,
        uint256 amountIn,
        uint256 amountOut
    );

    function requestQuote(RfqQuoteRequest calldata request) external returns (bytes32 quoteRequestId);

    function acceptQuote(bytes32 quoteId) external;
}
