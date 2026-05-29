// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  ManualPriceFeed
/// @notice Minimal owner-settable, Chainlink-AggregatorV3-compatible price feed. A self-published
///         price source for currencies that have NO third-party feed on Arc (e.g. CAD/USD for QCAD).
///         Wired into FxOracleV2's Chainlink fallback via `setChainlinkFeed(token, thisFeed)`.
/// @dev    8 decimals (Chainlink FX convention). `updatedAt` is the last `setPrice` block time, so
///         FxOracleV2's `chainlinkMaxAge` staleness gate still applies — a keeper must refresh the
///         price within that window. Owner is the protocol admin/keeper (a timelock on mainnet).
contract ManualPriceFeed {
    address public owner;
    uint8 public immutable decimals;
    string public description;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _round;

    error NotOwner();
    error ZeroAddress();
    error NonPositivePrice();

    event PriceSet(int256 answer, uint256 updatedAt, uint80 roundId);
    event OwnerTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint8 dec, string memory desc, int256 initialAnswer, address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (initialAnswer <= 0) revert NonPositivePrice();
        decimals = dec;
        description = desc;
        owner = owner_;
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
        _round = 1;
    }

    function setPrice(int256 answer) external onlyOwner {
        if (answer <= 0) revert NonPositivePrice();
        _answer = answer;
        _updatedAt = block.timestamp;
        unchecked {
            _round += 1;
        }
        emit PriceSet(answer, block.timestamp, _round);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }
}
