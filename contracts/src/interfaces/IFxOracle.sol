// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFxOracle
/// @notice Single read path for all on-chain price reads in fx-Telaraña. No contract
///         outside `FxOracle.sol` MAY call Pyth, RedStone, or Chainlink SDKs directly.
///
/// Mid is returned in 1e18 fixed-point: midE18 = (quote / base) * 1e18.
/// Example: getMid(EURC, USDC) ~= 1.08e18 when 1 EURC = 1.08 USDC.
///
/// Two read modes:
///   * getMid()           — pure view. Reverts if cached prices are stale, deviated,
///                          or outside Pyth confidence band.
///   * getMidWithUpdate() — payable. Caller bundles fresh signed price payloads from
///                          Pyth Hermes + RedStone gateway, oracle verifies + caches,
///                          then returns mid. Use this inside the same tx as a swap
///                          / borrow / liquidate to avoid staleness reverts.
interface IFxOracle {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OracleStale(uint256 publishedAt, uint256 maxAge);
    error OracleDeviation(uint256 primaryE18, uint256 secondaryE18, uint256 bpsObserved, uint256 bpsMax);
    error OracleLowConfidence(uint256 confBps, uint256 maxConfBps);
    error OracleFeedUnknown(address base, address quote);

    /*//////////////////////////////////////////////////////////////
                                READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the mid price of (base/quote) using last cached values.
    /// @dev Reverts on staleness, deviation, or low confidence.
    function getMid(address base, address quote)
        external
        view
        returns (uint256 midE18, uint256 publishedAt);

    /// @notice Updates Pyth + RedStone price caches inline, then returns mid.
    /// @param pythUpdate Pyth Hermes price-update payloads (variable len).
    /// @param redstoneUpdate RedStone signed-data payload (chain-agnostic pull mode).
    /// @dev Caller MUST forward enough msg.value to pay Pyth's `updateFee`.
    function getMidWithUpdate(
        address base,
        address quote,
        bytes[] calldata pythUpdate,
        bytes calldata redstoneUpdate
    ) external payable returns (uint256 midE18, uint256 publishedAt);

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns config parameters for off-chain consumers.
    function config()
        external
        view
        returns (
            uint256 maxOracleAge,         // staleness window (seconds), default 60
            uint256 maxDeviationBps,      // primary-vs-secondary gate (bps), default 50
            uint256 maxConfidenceBps      // Pyth conf-interval gate (bps), default 30
        );
}
