// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {IFxOracle} from "../interfaces/IFxOracle.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title MorphoOracleAdapter
/// @notice Adapts `IFxOracle.getMid` into Morpho Blue's `IOracle.price()` ABI.
///
/// Morpho Blue contract expects `price()` to return the price of 1 unit of
/// collateral token denominated in loan token, scaled to:
///     price * 10^(36 + loanDecimals - collateralDecimals)
///
/// One adapter per Morpho market. Cheap to deploy; immutable.
contract MorphoOracleAdapter is IOracle {
    IFxOracle public immutable FX_ORACLE;
    address  public immutable LOAN_TOKEN;
    address  public immutable COLLATERAL_TOKEN;

    /// @notice 10^(36 + loanDecimals - collateralDecimals).
    uint256 public immutable SCALE_FACTOR;

    error ZeroAddress();

    constructor(address fxOracle, address loanToken, address collateralToken) {
        if (fxOracle == address(0) || loanToken == address(0) || collateralToken == address(0)) revert ZeroAddress();
        FX_ORACLE = IFxOracle(fxOracle);
        LOAN_TOKEN = loanToken;
        COLLATERAL_TOKEN = collateralToken;

        uint256 ld = IERC20Decimals(loanToken).decimals();
        uint256 cd = IERC20Decimals(collateralToken).decimals();
        // 36 + ld - cd; for USDC/EURC (both 6) this is 36.
        SCALE_FACTOR = 10 ** (36 + ld - cd);
    }

    /// @notice Returns collateral-denominated-in-loan, scaled per Morpho spec.
    /// @dev    `IFxOracle.getMid(collateral, loan)` returns mid * 1e18 where
    ///         mid = price of 1 collateral in loan units. Multiply by 10^(18 + ld - cd)
    ///         to land at Morpho's 1e36-base scale.
    function price() external view override returns (uint256) {
        (uint256 midE18, ) = FX_ORACLE.getMid(COLLATERAL_TOKEN, LOAN_TOKEN);
        // midE18 ranges around 1e18 for USDC/EURC. Morpho expects:
        //   price = midRaw * 10^(36 + ld - cd)
        // We have midE18 = midRaw * 1e18, so:
        //   price = (midE18 / 1e18) * 10^(36 + ld - cd) = midE18 * 10^(18 + ld - cd)
        //         = midE18 * SCALE_FACTOR / 1e18.
        return (midE18 * SCALE_FACTOR) / 1e18;
    }
}
