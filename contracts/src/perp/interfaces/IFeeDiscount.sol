// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title IFeeDiscount
/// @notice Perp trading-fee discount source. Returns a basis-point discount
///         (0..5000 = 0%..50%) for a given trader. Implementations MAY return
///         values up to 5000; the caller (clearinghouse) MUST still clamp,
///         since this is an untrusted external surface.
interface IFeeDiscount {
    /// @notice Discount in basis points applied to a trader's perp trading fee.
    /// @param trader The trader address being charged a fee.
    /// @return bps Discount in basis points, expected 0..5000 (caller clamps).
    function discountBps(address trader) external view returns (uint16 bps);
}
