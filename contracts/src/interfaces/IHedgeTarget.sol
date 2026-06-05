// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title  IHedgeTarget
/// @notice The on-chain hedge TARGET source. `FxHedgeHook` satisfies this via its public
///         `poolHedgeSizeE18` mapping getter: it computes, in `afterSwap`/`afterAddLiquidity`,
///         the perp hedge size (E18, negative = short) that would make a pool delta-neutral.
/// @dev    Lets `FxHedgeExecutor` read the target without driving a full v4 swap, and keeps the
///         executor decoupled from the hook's internals.
interface IHedgeTarget {
    /// @notice Target hedge perp size for `poolId`, 1e18-scaled. Negative = short.
    function poolHedgeSizeE18(bytes32 poolId) external view returns (int256);
}
