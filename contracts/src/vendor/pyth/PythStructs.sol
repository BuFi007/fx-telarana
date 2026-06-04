// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @notice Minimal Pyth structs used by FxOracle and local tests.
contract PythStructs {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }
}
