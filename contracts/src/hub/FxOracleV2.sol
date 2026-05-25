// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {FxOracle} from "./FxOracle.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title FxOracleV2
/// @notice Extends FxOracle with Chainlink AggregatorV3 as a tertiary fallback.
///         Price resolution order: Pyth → RedStone → Chainlink.
///
///         Deploy as a new oracle, then deploy a new clearinghouse pointing to it
///         (FxPerpClearinghouse.ORACLE is immutable). Existing Pyth + RedStone
///         feeds carry over — just register Chainlink aggregators per token.
contract FxOracleV2 is FxOracle {

    mapping(address token => address aggregator) public chainlinkFeedOf;
    uint256 public chainlinkMaxAge;

    error ChainlinkFeedUnknown(address token);
    error ChainlinkStalePrice(address token, uint256 updatedAt, uint256 maxAge);
    error ChainlinkNegativePrice(address token);

    event ChainlinkFeedSet(address indexed token, address indexed aggregator);
    event ChainlinkMaxAgeSet(uint256 maxAge);

    constructor(
        address pyth_,
        address initialAdmin,
        uint256 maxOracleAge_,
        uint256 maxDeviationBps_,
        uint256 maxConfidenceBps_,
        uint256 chainlinkMaxAge_
    )
        FxOracle(pyth_, initialAdmin, maxOracleAge_, maxDeviationBps_, maxConfidenceBps_)
    {
        chainlinkMaxAge = chainlinkMaxAge_;
    }

    function setChainlinkFeed(address token, address aggregator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0) && aggregator != address(0));
        chainlinkFeedOf[token] = aggregator;
        emit ChainlinkFeedSet(token, aggregator);
    }

    function setChainlinkMaxAge(uint256 maxAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxAge > 0 && maxAge <= 86400);
        chainlinkMaxAge = maxAge;
        emit ChainlinkMaxAgeSet(maxAge);
    }

    /// @notice Pyth → RedStone → Chainlink fallback chain.
    function getMid(address base, address quote)
        public
        view
        override
        returns (uint256 midE18, uint256 publishedAt)
    {
        // 1. Pyth (cheapest, pull-based, confidence-gated)
        try this.getMidFromPyth(base, quote) returns (uint256 m, uint256 t) {
            return (m, t);
        } catch {}

        // 2. RedStone (pull-based, signed payload in calldata)
        try this._getMidFromRedstoneExternal(base, quote) returns (uint256 m, uint256 t) {
            return (m, t);
        } catch {}

        // 3. Chainlink (push-based, on-chain aggregator)
        return _getMidFromChainlink(base, quote);
    }

    /// @dev External wrapper for _getMidFromRedstone so getMid can
    ///      try/catch it. The original FxOracle.getMid calls it directly
    ///      (internal), which propagates the revert.
    function _getMidFromRedstoneExternal(address base, address quote)
        external
        view
        returns (uint256 midE18, uint256 publishedAt)
    {
        return _getMidFromRedstone(base, quote);
    }

    function _getMidFromChainlink(address base, address quote)
        internal
        view
        returns (uint256 midE18, uint256 publishedAt)
    {
        (uint256 basePrice, uint8 baseDec, uint256 baseUpdated) = _chainlinkPrice(base);
        (uint256 quotePrice, uint8 quoteDec, uint256 quoteUpdated) = _chainlinkPrice(quote);

        uint256 baseE18 = basePrice * (10 ** (18 - baseDec));
        uint256 quoteE18 = quotePrice * (10 ** (18 - quoteDec));

        midE18 = (baseE18 * 1e18) / quoteE18;
        publishedAt = baseUpdated < quoteUpdated ? baseUpdated : quoteUpdated;
    }

    function _chainlinkPrice(address token)
        internal
        view
        returns (uint256 price, uint8 dec, uint256 updatedAt)
    {
        address feed = chainlinkFeedOf[token];
        if (feed == address(0)) revert ChainlinkFeedUnknown(token);

        AggregatorV3Interface agg = AggregatorV3Interface(feed);
        dec = agg.decimals();
        (, int256 answer,, uint256 updated,) = agg.latestRoundData();

        if (answer <= 0) revert ChainlinkNegativePrice(token);
        if (chainlinkMaxAge > 0 && block.timestamp - updated > chainlinkMaxAge) {
            revert ChainlinkStalePrice(token, updated, chainlinkMaxAge);
        }

        price = uint256(answer);
        updatedAt = updated;
    }
}
