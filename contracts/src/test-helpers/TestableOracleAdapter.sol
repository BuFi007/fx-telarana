// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IOracle} from "morpho-blue/interfaces/IOracle.sol";

/// @title TestableOracleAdapter
/// @notice Morpho Blue IOracle with a single owner-settable `price()`. ONLY for
///         liquidation drills + integration testing on testnets. Production
///         markets MUST use the real `MorphoOracleAdapter` which reads from
///         `IFxOracle` (Pyth + RedStone fallback).
///
/// Morpho expects `price()` to return the collateral-per-loan price scaled by
/// `10 ** (36 + loanDecimals - collateralDecimals)`. For our USDC/EURC market
/// (both 6 decimals) the natural scale is 1e36.
contract TestableOracleAdapter is IOracle {
    address public immutable OWNER;
    uint256 public price_;

    error NotOwner();
    error ZeroAddress();

    event PriceSet(uint256 oldPrice, uint256 newPrice);

    constructor(address owner_, uint256 initialPrice) {
        if (owner_ == address(0)) revert ZeroAddress();
        OWNER = owner_;
        price_ = initialPrice;
        emit PriceSet(0, initialPrice);
    }

    function price() external view returns (uint256) {
        return price_;
    }

    function setPrice(uint256 newPrice) external {
        if (msg.sender != OWNER) revert NotOwner();
        emit PriceSet(price_, newPrice);
        price_ = newPrice;
    }
}
