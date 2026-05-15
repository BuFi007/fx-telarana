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
    error RedstoneFeedUnknown(address token);

    /*//////////////////////////////////////////////////////////////
                                READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pyth-only mid price of (base/quote). View. Cheap.
    /// @dev    Reverts on Pyth staleness or low confidence. Does NOT verify
    ///         against the secondary (RedStone) source — use `getMidVerified`
    ///         for the deviation-gated read used by liquidators and the swap hook.
    function getMid(address base, address quote)
        external
        view
        returns (uint256 midE18, uint256 publishedAt);

    /// @notice Pyth mid cross-checked against RedStone signed payload appended
    ///         to msg.data (RedStone pull-mode). Reverts if RedStone signers
    ///         disagree with Pyth beyond the configured deviation gate.
    /// @dev    Callers MUST wrap their tx with the RedStone SDK so the signed
    ///         price payload is in calldata tail. Use this for liquidation,
    ///         swap, and any borrow-affecting action.
    function getMidVerified(address base, address quote)
        external
        view
        returns (uint256 midE18, uint256 publishedAt);

    /// @notice Update Pyth feeds inline (pays Pyth fee from msg.value), then
    ///         return the deviation-gated mid. RedStone payload is read from
    ///         msg.data tail (do not pass it as an argument).
    function getMidWithUpdate(
        address base,
        address quote,
        bytes[] calldata pythUpdate
    ) external payable returns (uint256 midE18, uint256 publishedAt);

    /// @notice Update Pyth feeds inline and return the Pyth-only mid (no RedStone
    ///         deviation gate). Use only on chains without RedStone signers; rely
    ///         on Pyth confidence bands for safety.
    function getMidWithUpdatePyth(
        address base,
        address quote,
        bytes[] calldata pythUpdate
    ) external payable returns (uint256 midE18, uint256 publishedAt);

    /// @notice Single-feed read: `token`'s USD price, 1e18-scaled.
    /// @dev    Spec §6.1 integrator surface — convenience over `getMid(token, USD_anchor)`.
    ///         Reads the token's Pyth feed alone (no RedStone deviation gate). Use this
    ///         for off-chain quote calculation; on-chain swap/borrow paths should still
    ///         use `getMidVerified` to enforce the secondary cross-check.
    function priceOf(address token) external view returns (uint256 priceE18, uint256 publishedAt);

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
