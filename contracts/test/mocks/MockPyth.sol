// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @notice Minimal Pyth mock for unit testing FxOracle.
contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) internal _prices;
    mapping(bytes32 => PythStructs.Price) internal _emaPrices;

    uint256 public updateFeeWei = 0;
    uint256 public validTimePeriod = 60;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = PythStructs.Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        _emaPrices[id] = PythStructs.Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function setUpdateFee(uint256 fee) external {
        updateFeeWei = fee;
    }

    function getPrice(bytes32 id) external view returns (PythStructs.Price memory) {
        return _prices[id];
    }

    function getEmaPrice(bytes32 id) external view returns (PythStructs.Price memory) {
        return _emaPrices[id];
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return _prices[id];
    }

    function getEmaPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return _emaPrices[id];
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory p) {
        p = _prices[id];
        require(block.timestamp - p.publishTime <= age, "StalePrice()");
    }

    function getEmaPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory p) {
        p = _emaPrices[id];
        require(block.timestamp - p.publishTime <= age, "StalePrice()");
    }

    function getValidTimePeriod() external view returns (uint256) {
        return validTimePeriod;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= updateFeeWei, "InsufficientFee");
    }

    function updatePriceFeedsIfNecessary(bytes[] calldata, bytes32[] calldata, uint64[] calldata) external payable {
        require(msg.value >= updateFeeWei, "InsufficientFee");
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFeeWei;
    }

    function parsePriceFeedUpdates(
        bytes[] calldata,
        bytes32[] calldata,
        uint64,
        uint64
    ) external payable returns (PythStructs.PriceFeed[] memory) {
        revert("not implemented");
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata,
        bytes32[] calldata,
        uint64,
        uint64
    ) external payable returns (PythStructs.PriceFeed[] memory) {
        revert("not implemented");
    }
}
