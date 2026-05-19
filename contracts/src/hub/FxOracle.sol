// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {
    PrimaryProdDataServiceConsumerBase
} from "@redstone-finance/evm-connector/data-services/PrimaryProdDataServiceConsumerBase.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";

/// @title FxOracle
/// @notice The single permissionless price-read surface for fx-Telaraña.
///         Pyth pull oracle is primary. RedStone pull-mode (signed payload
///         appended to msg.data by the client SDK) is the decentralized
///         secondary used by `getMidVerified`. A deviation gate forces
///         convergence; a confidence-band gate trips on shaky Pyth feeds.
///
/// 24/7. No forex-market-hours logic. USDC and EURC are ERC-20s onchain.
///
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │  getMid()           — Pyth-only view (cheap, no deviation check)        │
/// │  getMidVerified()   — Pyth + RedStone-from-msg.data deviation gate      │
/// │  getMidWithUpdate() — payable: updatePriceFeeds(Pyth) + getMidVerified  │
/// └─────────────────────────────────────────────────────────────────────────┘
contract FxOracle is IFxOracle, PrimaryProdDataServiceConsumerBase, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IPyth public immutable PYTH;

    /// @notice Reads (price views) never gate on Pausable — they must always
    ///         succeed even during an incident. Mutators gate on
    ///         `DEFAULT_ADMIN_ROLE` only (timelock-gated per spec §10.3).
    uint256 public maxOracleAge;
    uint256 public maxDeviationBps;
    uint256 public maxConfidenceBps;

    /// @notice token → Pyth feed id. Usually token/USD; set
    ///         `pythFeedInvertedOf[token]` when Pyth publishes USD/token.
    mapping(address token => bytes32 pythFeedId) public pythFeedOf;

    /// @notice token → true when the configured Pyth feed must be inverted
    ///         before it is treated as token/USD.
    mapping(address token => bool inverted) public pythFeedInvertedOf;

    /// @notice token → RedStone data feed id (e.g. `bytes32("USDC")`).
    mapping(address token => bytes32 redstoneFeedId) public redstoneFeedOf;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidConfig();
    error ZeroAddress();
    error InsufficientPythFee(uint256 fee, uint256 sent);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeedSet(address indexed token, bytes32 pythFeedId);
    event PythFeedConfigSet(address indexed token, bytes32 pythFeedId, bool inverted);
    event RedstoneFeedSet(address indexed token, bytes32 redstoneFeedId);
    event ConfigUpdated(uint256 maxOracleAge, uint256 maxDeviationBps, uint256 maxConfidenceBps);

    // Hard upper bounds on oracle config. Constructor + setConfig enforce
    // both `> 0` (rejecting no-op gates) AND `<= MAX_*` (defense-in-depth
    // against admin key compromise widening the gate to useless values).
    // Picked to match documented defaults at ~10× headroom: 30 min
    // staleness, 5% deviation, 5% confidence band. Past these the gate
    // is operationally meaningless — a healthy asset doesn't need 24h
    // staleness tolerance, and a 65% confidence band silences the gate
    // entirely (codex contract review P2 #7).
    uint256 public constant MAX_ORACLE_AGE_HARD_CAP = 30 minutes;
    uint256 public constant MAX_DEVIATION_BPS_HARD_CAP = 500;     // 5.00%
    uint256 public constant MAX_CONFIDENCE_BPS_HARD_CAP = 500;    // 5.00%

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    /// @param initialAdmin Address that initially holds `DEFAULT_ADMIN_ROLE`.
    ///                     Deploy scripts grant this to the deployer for
    ///                     bootstrap setup, then atomically transfer to the
    ///                     `FxTimelock` and renounce the deployer's role.
    constructor(
        address pyth_,
        address initialAdmin,
        uint256 maxOracleAge_,
        uint256 maxDeviationBps_,
        uint256 maxConfidenceBps_
    ) {
        if (pyth_ == address(0) || initialAdmin == address(0)) revert ZeroAddress();
        _validateConfig(maxOracleAge_, maxDeviationBps_, maxConfidenceBps_);

        PYTH = IPyth(pyth_);
        maxOracleAge = maxOracleAge_;
        maxDeviationBps = maxDeviationBps_;
        maxConfidenceBps = maxConfidenceBps_;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);

        emit ConfigUpdated(maxOracleAge_, maxDeviationBps_, maxConfidenceBps_);
    }

    /// @dev Shared by constructor + `setConfig`. Both `> 0` (no-op gate)
    ///      AND `<= MAX_*` (defense vs. admin compromise widening gate).
    function _validateConfig(uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps) internal pure {
        if (maxAge == 0 || maxDevBps == 0 || maxConfBps == 0) revert InvalidConfig();
        if (maxAge > MAX_ORACLE_AGE_HARD_CAP) revert InvalidConfig();
        if (maxDevBps > MAX_DEVIATION_BPS_HARD_CAP) revert InvalidConfig();
        if (maxConfBps > MAX_CONFIDENCE_BPS_HARD_CAP) revert InvalidConfig();
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setFeed(address token, bytes32 pythFeedId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPythFeed(token, pythFeedId, false);
    }

    function setPythFeedConfig(address token, bytes32 pythFeedId, bool inverted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPythFeed(token, pythFeedId, inverted);
    }

    function _setPythFeed(address token, bytes32 pythFeedId, bool inverted) internal {
        if (token == address(0) || pythFeedId == bytes32(0)) revert InvalidConfig();
        pythFeedOf[token] = pythFeedId;
        pythFeedInvertedOf[token] = inverted;
        emit FeedSet(token, pythFeedId);
        emit PythFeedConfigSet(token, pythFeedId, inverted);
    }

    function setRedstoneFeed(address token, bytes32 redstoneFeedId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || redstoneFeedId == bytes32(0)) revert InvalidConfig();
        redstoneFeedOf[token] = redstoneFeedId;
        emit RedstoneFeedSet(token, redstoneFeedId);
    }

    function setConfig(uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateConfig(maxAge, maxDevBps, maxConfBps);
        maxOracleAge = maxAge;
        maxDeviationBps = maxDevBps;
        maxConfidenceBps = maxConfBps;
        emit ConfigUpdated(maxAge, maxDevBps, maxConfBps);
    }

    /*//////////////////////////////////////////////////////////////
                                READS
    //////////////////////////////////////////////////////////////*/

    function config() external view returns (uint256 maxAge, uint256 maxDevBps, uint256 maxConfBps) {
        return (maxOracleAge, maxDeviationBps, maxConfidenceBps);
    }

    /// @notice Single-feed read: `token`'s USD price, 1e18-scaled.
    /// @dev    Spec §6.1 integrator surface. Reads the token's Pyth feed alone
    ///         (no RedStone cross-check). For on-chain price gates that need
    ///         deviation safety, use `getMidVerified(base, quote)` instead.
    function priceOf(address token) external view returns (uint256 priceE18, uint256 publishedAt) {
        bytes32 feedId = pythFeedOf[token];
        if (feedId == bytes32(0)) revert OracleFeedUnknown(token, address(0));
        PythStructs.Price memory p = PYTH.getPriceNoOlderThan(feedId, maxOracleAge);
        _assertPythConfidence(p);
        priceE18 = _pythPriceToE18(p, pythFeedInvertedOf[token]);
        publishedAt = p.publishTime;
    }

    /// @notice Robust mid read with Pyth → RedStone fallback.
    /// @dev    1. Try Pyth (fresh + within confidence band). If it works, return.
    ///         2. Otherwise try RedStone payload from msg.data tail.
    ///         3. If both fail, propagate the RedStone error (more informative).
    ///
    ///         Pyth is preferred when both are valid because Pyth confidence
    ///         intervals are tracked explicitly and we set tight gates.
    ///
    ///         For STRICTLY-BOTH-AGREE semantics (liquidation safety), use
    ///         `getMidVerified` which enforces deviation between the two.
    function getMid(address base, address quote) public view returns (uint256 midE18, uint256 publishedAt) {
        // Try Pyth path. View-function try/catch requires an external self-call.
        try this.getMidFromPyth(base, quote) returns (uint256 m, uint256 t) {
            return (m, t);
        } catch {
            // Pyth unavailable. Fall through to RedStone.
        }
        return _getMidFromRedstone(base, quote);
    }

    /// @notice Pyth-only mid. Reverts on staleness, low confidence, or unknown feed.
    /// @dev    Marked external so `getMid` can call it via try/catch. Internally
    ///         delegates to `_getMidFromPyth` so other internal callers keep
    ///         their gas profile.
    function getMidFromPyth(address base, address quote) external view returns (uint256 midE18, uint256 publishedAt) {
        return _getMidFromPyth(base, quote);
    }

    function _getMidFromPyth(address base, address quote) internal view returns (uint256 midE18, uint256 publishedAt) {
        bytes32 baseFeed = pythFeedOf[base];
        bytes32 quoteFeed = pythFeedOf[quote];
        if (baseFeed == bytes32(0) || quoteFeed == bytes32(0)) {
            revert OracleFeedUnknown(base, quote);
        }

        PythStructs.Price memory pBase = PYTH.getPriceNoOlderThan(baseFeed, maxOracleAge);
        PythStructs.Price memory pQuote = PYTH.getPriceNoOlderThan(quoteFeed, maxOracleAge);

        _assertPythConfidence(pBase);
        _assertPythConfidence(pQuote);

        midE18 = _pythPairToE18(pBase, pythFeedInvertedOf[base], pQuote, pythFeedInvertedOf[quote]);
        publishedAt = pBase.publishTime < pQuote.publishTime ? pBase.publishTime : pQuote.publishTime;
    }

    function _getMidFromRedstone(address base, address quote)
        internal
        view
        returns (uint256 midE18, uint256 publishedAt)
    {
        bytes32 baseRed = redstoneFeedOf[base];
        bytes32 quoteRed = redstoneFeedOf[quote];
        if (baseRed == bytes32(0)) revert RedstoneFeedUnknown(base);
        if (quoteRed == bytes32(0)) revert RedstoneFeedUnknown(quote);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = baseRed;
        ids[1] = quoteRed;
        uint256[] memory values = _redstoneFetch(ids);

        if (values[1] == 0) revert OracleFeedUnknown(base, quote);
        midE18 = (values[0] * 1e18) / values[1];
        publishedAt = block.timestamp; // RedStone payload validity gated by
        // validateTimestamp; we treat the read
        // as "now" for downstream staleness checks.
    }

    /// @notice Strict mid: BOTH Pyth and RedStone must succeed AND agree within
    ///         deviation bound. For liquidation safety.
    function getMidVerified(address base, address quote) public view returns (uint256 midE18, uint256 publishedAt) {
        (midE18, publishedAt) = _getMidFromPyth(base, quote);

        bytes32 baseRed = redstoneFeedOf[base];
        bytes32 quoteRed = redstoneFeedOf[quote];
        if (baseRed == bytes32(0)) revert RedstoneFeedUnknown(base);
        if (quoteRed == bytes32(0)) revert RedstoneFeedUnknown(quote);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = baseRed;
        ids[1] = quoteRed;
        uint256[] memory values = _redstoneFetch(ids);

        if (values[1] == 0) revert OracleDeviation(midE18, 0, type(uint256).max, maxDeviationBps);
        uint256 redstoneMidE18 = (values[0] * 1e18) / values[1];

        _assertDeviation(midE18, redstoneMidE18);
    }

    /// @notice Update Pyth + return verified mid (Pyth + RedStone-from-msg.data).
    /// @dev    Strict path — requires RedStone signers configured for both tokens.
    ///         On chains without RedStone (e.g. Base Sepolia), use
    ///         `getMidWithUpdatePyth` instead.
    function getMidWithUpdate(address base, address quote, bytes[] calldata pythUpdate)
        external
        payable
        returns (uint256 midE18, uint256 publishedAt)
    {
        _updatePyth(pythUpdate);
        (midE18, publishedAt) = getMidVerified(base, quote);
    }

    /// @notice Update Pyth + return Pyth-only mid. Skips the RedStone deviation
    ///         gate, so callers MUST treat the result as freshness-only and rely
    ///         on Pyth confidence bands for safety.
    /// @dev    Intended for chains that don't have RedStone signers deployed yet.
    function getMidWithUpdatePyth(address base, address quote, bytes[] calldata pythUpdate)
        external
        payable
        returns (uint256 midE18, uint256 publishedAt)
    {
        _updatePyth(pythUpdate);
        return _getMidFromPyth(base, quote);
    }

    function _updatePyth(bytes[] calldata pythUpdate) internal {
        uint256 fee = PYTH.getUpdateFee(pythUpdate);
        if (msg.value < fee) revert InsufficientPythFee(fee, msg.value);

        PYTH.updatePriceFeeds{value: fee}(pythUpdate);

        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            REDSTONE EXTRACTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal hook: fetch RedStone numeric values for `feedIds`.
    /// @dev    Production path reads signed payloads from msg.data via the
    ///         RedStone consumer base. Test subclasses can override this to
    ///         return mocked values without constructing real signed payloads.
    function _redstoneFetch(bytes32[] memory feedIds) internal view virtual returns (uint256[] memory) {
        return getOracleNumericValuesFromTxMsg(feedIds);
    }

    /// @dev RedStone consumer base requires a max timestamp deviation. We tie
    ///      it to our oracle age so admin only tunes one knob.
    function validateTimestamp(uint256 receivedTimestampMilliseconds) public view virtual override {
        uint256 receivedSecs = receivedTimestampMilliseconds / 1000;
        if (block.timestamp > receivedSecs && block.timestamp - receivedSecs > maxOracleAge) {
            revert("RedStone payload stale");
        }
        // Allow up to 60s of clock-skew tolerance forward (RedStone default behavior).
        if (receivedSecs > block.timestamp && receivedSecs - block.timestamp > 60) {
            revert("RedStone payload from future");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _assertPythConfidence(PythStructs.Price memory p) internal view {
        if (p.price <= 0) revert OracleLowConfidence(type(uint256).max, maxConfidenceBps);
        uint256 absPrice = uint256(uint64(p.price));
        uint256 confBps = (uint256(p.conf) * 10_000) / absPrice;
        if (confBps > maxConfidenceBps) {
            revert OracleLowConfidence(confBps, maxConfidenceBps);
        }
    }

    function _pythPairToE18(
        PythStructs.Price memory pBase,
        bool baseInverted,
        PythStructs.Price memory pQuote,
        bool quoteInverted
    ) internal pure returns (uint256 midE18) {
        uint256 baseE18 = _pythPriceToE18(pBase, baseInverted);
        uint256 quoteE18 = _pythPriceToE18(pQuote, quoteInverted);
        if (quoteE18 == 0) return 0;
        midE18 = (baseE18 * 1e18) / quoteE18;
    }

    function _pythPriceToE18(PythStructs.Price memory p, bool inverted) internal pure returns (uint256) {
        uint256 priceE18 = _toE18(p);
        if (!inverted) return priceE18;
        if (priceE18 == 0) revert OracleLowConfidence(type(uint256).max, type(uint256).max);
        return 1e36 / priceE18;
    }

    function _toE18(PythStructs.Price memory p) internal pure returns (uint256) {
        uint256 v = uint256(uint64(p.price));
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
}
