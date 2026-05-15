// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title FxRouterLib
/// @notice EIP-712 struct + typehash + hashing helpers for the signed-intent
///         routing layer (Phase 2.6R, `FxRouter`).
/// @dev    PURE LIBRARY — no storage, no external calls, no balance handling.
///         Lives here so the SDK (`packages/sdk/src/fxRouter/`) and the
///         in-flight `FxRouter.sol` contract can both reference one canonical
///         layout. Changes here require coordinated SDK + contract redeploy.
///
///         Spec: `docs/SPEC_FX_ROUTER_AND_PASILLO_QUOTE_API.md` §3.2.
library FxRouterLib {
    /*//////////////////////////////////////////////////////////////
                              EIP-712 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Signed intent for a single FX swap, schema-aligned with Circle
    ///         StableFX's `TakerDetails` so a single client envelope can be
    ///         routed to either rail by Pasillo (or any aggregator).
    /// @param taker              Signer; must equal SignatureChecker-validated address.
    /// @param recipient          Where buyToken lands. Always signed, never
    ///                           msg.sender-derived. Ghost Mode recipients are
    ///                           selected by the Bufi privacy route.
    /// @param sellToken          Token pulled from taker via Permit2.
    /// @param buyToken           Token delivered to recipient.
    /// @param sellAmount         Exact sell amount (this phase = exact-input only).
    ///                           MUST equal the Permit2 PermitTransferFrom amount.
    /// @param minBuyAmount       Slippage floor on output.
    /// @param deadline           Unix seconds; intent expires.
    /// @param feeBps             Protocol fee in the 1e14 BPS_DENOMINATOR (Sera convention).
    /// @param tenor              0 = instant (only supported value this phase);
    ///                           1 = hourly, 2 = daily (reserved for future async settlement).
    /// @param quoteId            Off-chain quote ID (Pasillo / StableFX / other aggregator).
    /// @param uuid               Per-user nonce, recorded in `isIntentUuidUsed[taker][uuid]`.
    struct FxIntent {
        address taker;
        address recipient;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 minBuyAmount;
        uint48  deadline;
        uint48  feeBps;
        uint8   tenor;
        bytes32 quoteId;
        uint256 uuid;
    }

    /// @notice keccak256 of the typed-data string for `FxIntent`.
    /// @dev    Pin this — changing field order or types invalidates every
    ///         existing signed envelope. Cross-test against the TypeScript
    ///         SDK builder via `packages/sdk/src/fxRouter/__tests__/`.
    bytes32 internal constant FX_INTENT_TYPEHASH = keccak256(
        "FxIntent(address taker,address recipient,address sellToken,address buyToken,uint256 sellAmount,uint256 minBuyAmount,uint48 deadline,uint48 feeBps,uint8 tenor,bytes32 quoteId,uint256 uuid)"
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sera-compatible sub-bps fee denominator. Permits fees as small as
    ///         $0.01 on $1M trades (i.e., 1 / 1e14 of the trade amount).
    uint256 internal constant BPS_DENOMINATOR = 1e14;

    /// @notice 50 bps absolute hard cap (50 * BPS_DENOMINATOR / 10_000). Admin
    ///         `maxFeeBps` must stay below this — institutional FX is ≤10 bps
    ///         typical; 50 bps gives headroom for thin EM pairs.
    uint48 internal constant MAX_FEE_BPS_HARD_CAP = uint48(50 * BPS_DENOMINATOR / 10_000);

    /// @notice Only tenor value supported in Phase 2.6R. Reserved range above.
    uint8 internal constant TENOR_INSTANT = 0;

    /// @notice Anti-stale-far-future guard: reject intents whose `deadline` is
    ///         more than this many seconds in the future at submission time.
    ///         Defends against long-lived signed envelopes leaking onto chain.
    uint256 internal constant MAX_DEADLINE_FUTURE = 1 hours;

    /*//////////////////////////////////////////////////////////////
                              PURE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the EIP-712 struct hash for an FxIntent.
    /// @dev    Returns the inner struct hash; callers wrap with their own
    ///         `_hashTypedDataV4` (Solady or OZ) which folds in the domain
    ///         separator. Keeping this pure makes it trivially auditable.
    function hashIntent(FxIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FX_INTENT_TYPEHASH,
                intent.taker,
                intent.recipient,
                intent.sellToken,
                intent.buyToken,
                intent.sellAmount,
                intent.minBuyAmount,
                intent.deadline,
                intent.feeBps,
                intent.tenor,
                intent.quoteId,
                intent.uuid
            )
        );
    }

    /// @notice Same as `hashIntent` for memory inputs (test helpers, off-chain
    ///         builders that don't have calldata).
    function hashIntentMemory(FxIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FX_INTENT_TYPEHASH,
                intent.taker,
                intent.recipient,
                intent.sellToken,
                intent.buyToken,
                intent.sellAmount,
                intent.minBuyAmount,
                intent.deadline,
                intent.feeBps,
                intent.tenor,
                intent.quoteId,
                intent.uuid
            )
        );
    }

    /// @notice Convenience: compute the protocol fee on a sell amount.
    /// @dev    No overflow concerns for `sellAmount <= type(uint128).max` and
    ///         `feeBps <= MAX_FEE_BPS_HARD_CAP` — 2^128 * 5e11 < 2^256.
    function computeFee(uint256 sellAmount, uint48 feeBps) internal pure returns (uint256) {
        return (sellAmount * uint256(feeBps)) / BPS_DENOMINATOR;
    }
}
