// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IFxFundingSettlementHook {
    function settleTraderFunding(address trader) external returns (int256 fundingPaid);
}
