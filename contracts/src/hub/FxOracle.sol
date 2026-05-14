// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IFxOracle} from "../interfaces/IFxOracle.sol";

/// @title FxOracle
/// @notice The single permissionless price-read surface for fx-Telaraña.
///         Pyth pull oracle is primary. RedStone pull-mode payloads (chain-agnostic,
///         no Arc-side deployment) are the decentralized secondary. A deviation
///         gate forces convergence; a confidence-band gate trips on shaky Pyth feeds.
///
/// 24/7. No forex-market-hours logic. USDC and EURC are ERC-20s onchain.
///
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │  IFxOracle.getMidWithUpdate(base, quote, pythUpdate, redstoneUpdate)    │
/// │       │                                                                 │
/// │       ├─► Pyth.updatePriceFeeds(pythUpdate) (payable)                   │
/// │       ├─► RedstoneConsumer.extractTimestamp/Value (TODO Phase 0.5)      │
/// │       ├─► getMid(base, quote)                                           │
/// │       │       │                                                         │
/// │       │       ├─► read Pyth feeds for base/USD and quote/USD            │
/// │       │       ├─► assert staleness, confidence                          │
/// │       │       ├─► (when redstoneCached) assert deviation                │
/// │       │       └─► return (base/quote) * 1e18                            │
/// │       │                                                                 │
/// │       └─► refund excess msg.value                                       │
/// └─────────────────────────────────────────────────────────────────────────┘
contract FxOracle is IFxOracle {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IPyth public immutable PYTH;

    address public owner;

    uint256 public maxOracleAge;        // staleness window (seconds)
    uint256 public maxDeviationBps;     // primary-vs-secondary gate
    uint256 public maxConfidenceBps;    // Pyth conf-interval gate

    /// @notice token → Pyth feed id (token/USD). Set by `setFeed`.
    mapping(address token => bytes32 pythFeedId) public pythFeedOf;

    /// @notice token → last cached RedStone price (1e18) and timestamp.
    ///         RedStone pull payloads are bundled into update calls; the consumer
    ///         logic extracts and caches here for deviation checks against Pyth.
    struct RedstoneCache {
        uint256 priceE18;
        uint256 publishedAt;
    }
    mapping(address token => RedstoneCache) public redstoneCache;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error InvalidConfig();
    error ZeroAddress();
    error InsufficientPythFee(uint256 fee, uint256 sent);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeedSet(address indexed token, bytes32 pythFeedId);
    event ConfigUpdated(uint256 maxOracleAge, uint256 maxDeviationBps, uint256 maxConfidenceBps);
    event OwnerTransferred(address indexed from, address indexed to);
    event RedstoneCached(address indexed token, uint256 priceE18, uint256 publishedAt);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address pyth_,
        address owner_,
        uint256 maxOracleAge_,
        uint256 maxDeviationBps_,
        uint256 maxConfidenceBps_
    ) {
        if (pyth_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (maxOracleAge_ == 0 || maxDeviationBps_ == 0 || maxConfidenceBps_ == 0) revert InvalidConfig();

        PYTH = IPyth(pyth_);
        owner = owner_;
        maxOracleAge = maxOracleAge_;
        maxDeviationBps = maxDeviationBps_;
        maxConfidenceBps = maxConfidenceBps_;

        emit OwnerTransferred(address(0), owner_);
        emit ConfigUpdated(maxOracleAge_, maxDeviationBps_, maxConfidenceBps_);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a Pyth feed id for `token`. Token price is denominated in USD.
    /// @dev    Behind a 48h timelock in production (the owner is a TimelockController).
    function setFeed(address token, bytes32 pythFeedId) external onlyOwner {
        if (token == address(0) || pythFeedId == bytes32(0)) revert InvalidConfig();
        pythFeedOf[token] = pythFeedId;
        emit FeedSet(token, pythFeedId);
    }

    function setConfig(uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps) external onlyOwner {
        if (maxAge == 0 || maxDevBps == 0 || maxConfBps == 0) revert InvalidConfig();
        maxOracleAge = maxAge;
        maxDeviationBps = maxDevBps;
        maxConfidenceBps = maxConfBps;
        emit ConfigUpdated(maxAge, maxDevBps, maxConfBps);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                READS
    //////////////////////////////////////////////////////////////*/

    function config()
        external
        view
        returns (uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps)
    {
        return (maxOracleAge, maxDeviationBps, maxConfidenceBps);
    }

    /// @notice Pure-view mid. Reverts on staleness, confidence, or deviation breaches.
    /// @dev    The mid is computed as (base/USD) / (quote/USD) so it's USD-denominated
    ///         pairs only at MVP. Both USDC/USD and EURC/USD have Pyth feeds.
    function getMid(address base, address quote)
        public
        view
        returns (uint256 midE18, uint256 publishedAt)
    {
        bytes32 baseFeed = pythFeedOf[base];
        bytes32 quoteFeed = pythFeedOf[quote];
        if (baseFeed == bytes32(0) || quoteFeed == bytes32(0)) {
            revert OracleFeedUnknown(base, quote);
        }

        PythStructs.Price memory pBase = PYTH.getPriceNoOlderThan(baseFeed, maxOracleAge);
        PythStructs.Price memory pQuote = PYTH.getPriceNoOlderThan(quoteFeed, maxOracleAge);

        _assertPythConfidence(pBase);
        _assertPythConfidence(pQuote);

        midE18 = _pythPairToE18(pBase, pQuote);
        publishedAt = pBase.publishTime < pQuote.publishTime ? pBase.publishTime : pQuote.publishTime;

        // Deviation gate vs RedStone cache (skip if not cached for either token —
        // primary-only mode is acceptable per design until RedStone payloads land).
        RedstoneCache memory rBase = redstoneCache[base];
        RedstoneCache memory rQuote = redstoneCache[quote];
        if (rBase.publishedAt != 0 && rQuote.publishedAt != 0) {
            if (
                block.timestamp - rBase.publishedAt > maxOracleAge
                    || block.timestamp - rQuote.publishedAt > maxOracleAge
            ) {
                // RedStone cache stale → treat as primary-only this read.
                return (midE18, publishedAt);
            }
            uint256 rMidE18 = (rBase.priceE18 * 1e18) / rQuote.priceE18;
            _assertDeviation(midE18, rMidE18);
        }
    }

    /// @notice Update Pyth (and RedStone cache when payload present) then return mid.
    /// @dev    `redstoneUpdate` is reserved for the RedStone consumer integration
    ///         (Phase 0.5). For Phase 0 ship we accept it as a sentinel — when len = 0
    ///         the function operates in Pyth-only mode and `getMid` skips deviation.
    function getMidWithUpdate(
        address base,
        address quote,
        bytes[] calldata pythUpdate,
        bytes calldata redstoneUpdate
    ) external payable returns (uint256 midE18, uint256 publishedAt) {
        uint256 fee = PYTH.getUpdateFee(pythUpdate);
        if (msg.value < fee) revert InsufficientPythFee(fee, msg.value);

        PYTH.updatePriceFeeds{value: fee}(pythUpdate);

        // RedStone update path is wired in Phase 0.5; placeholder so the ABI is stable.
        redstoneUpdate; // silence unused warning

        (midE18, publishedAt) = getMid(base, quote);

        // Refund any overpay.
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok, ) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _assertPythConfidence(PythStructs.Price memory p) internal view {
        if (p.price <= 0) revert OracleLowConfidence(type(uint256).max, maxConfidenceBps);
        // conf / |price| in bps
        uint256 absPrice = uint256(uint64(p.price));
        uint256 confBps = (uint256(p.conf) * 10_000) / absPrice;
        if (confBps > maxConfidenceBps) {
            revert OracleLowConfidence(confBps, maxConfidenceBps);
        }
    }

    function _pythPairToE18(PythStructs.Price memory pBase, PythStructs.Price memory pQuote)
        internal
        pure
        returns (uint256 midE18)
    {
        // Pyth prices are int64 + expo (typically -8). Normalize to 1e18.
        uint256 baseE18 = _toE18(pBase);
        uint256 quoteE18 = _toE18(pQuote);
        if (quoteE18 == 0) return 0;
        midE18 = (baseE18 * 1e18) / quoteE18;
    }

    function _toE18(PythStructs.Price memory p) internal pure returns (uint256) {
        // Assume non-negative price (asserted in confidence check).
        uint256 v = uint256(uint64(p.price));
        // expo is negative for normal feeds; convert to 1e18.
        int256 expo = int256(p.expo);
        if (expo <= -18) {
            return v / (10 ** uint256(-expo - 18));
        } else if (expo >= 0) {
            return v * (10 ** (18 + uint256(expo)));
        } else {
            return v * (10 ** uint256(18 + expo));
        }
    }

    function _assertDeviation(uint256 a, uint256 b) internal view {
        if (a == 0 || b == 0) return;
        uint256 diff = a > b ? a - b : b - a;
        uint256 bps = (diff * 10_000) / a;
        if (bps > maxDeviationBps) {
            revert OracleDeviation(a, b, bps, maxDeviationBps);
        }
    }

    /// @notice Test-only setter — REMOVE before mainnet. The production path writes
    ///         redstoneCache from a verified RedStone payload extracted in
    ///         `getMidWithUpdate`. Phase 0.5 replaces this with the consumer wiring.
    function _setRedstoneCacheForTest(address token, uint256 priceE18, uint256 publishedAt)
        external
        onlyOwner
    {
        redstoneCache[token] = RedstoneCache({priceE18: priceE18, publishedAt: publishedAt});
        emit RedstoneCached(token, priceE18, publishedAt);
    }
}
