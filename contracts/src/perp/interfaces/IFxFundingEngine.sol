// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxFundingEngine {
    function settleFunding(bytes32 marketId, address trader) external returns (int256 fundingPaid);
    function getFundingIndex(bytes32 marketId, uint64 version) external view returns (int256 cumulativeFundingE18);
    function pokeFundingRate(bytes32 marketId) external;
}
