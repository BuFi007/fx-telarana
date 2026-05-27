// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFxFundingEngine} from "./interfaces/IFxFundingEngine.sol";
import {IFxMarginAccount} from "./interfaces/IFxMarginAccount.sol";
import {IFxPerpClearinghouse} from "./interfaces/IFxPerpClearinghouse.sol";
import {FxPerpMath} from "./FxPerpMath.sol";

/// @title FxFundingEngine
/// @notice Perennial-style version-keyed peer-to-peer funding index.
/// @dev Reference: Perennial v2 `VersionLib._accumulateFunding` and
///      `Global/Local` accumulator split. This contract stores one cumulative
///      index per market version and settles each trader against the last
///      index they touched.
contract FxFundingEngine is IFxFundingEngine, AccessControl, Pausable {
    using Math for uint256;
    using SafeCast for uint256;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");

    struct FundingConfig {
        bool enabled;
        uint256 maxFundingRateBpsPerSecond;
        uint256 fundingVelocityBps;
    }

    struct FundingState {
        uint64 currentVersion;
        uint256 lastUpdate;
        int256 currentRateE18PerSecond;
        int256 cumulativeFundingE18;
    }

    IFxPerpClearinghouse public immutable CLEARINGHOUSE;
    IFxMarginAccount public immutable MARGIN;
    uint8 public immutable MARGIN_DECIMALS;

    /// @notice Global circuit breaker: absolute cap on the funding rate (E18 per second).
    ///         Default 1e14 = 0.01% per second ~ 315% APR.
    uint256 public maxAbsFundingRateE18 = 1e14;

    mapping(bytes32 marketId => FundingConfig config) public fundingConfig;
    mapping(bytes32 marketId => FundingState state) public fundingState;
    mapping(bytes32 marketId => mapping(uint64 version => int256 index)) public fundingIndex;
    mapping(bytes32 marketId => mapping(address trader => int256 index)) public traderFundingIndex;

    event FundingConfigured(bytes32 indexed marketId, FundingConfig config);
    event FundingPoked(bytes32 indexed marketId, uint64 version, int256 rateE18PerSecond, int256 cumulativeFundingE18);
    event FundingSettled(bytes32 indexed marketId, address indexed trader, int256 fundingPaid);
    event FundingRateClamped(bytes32 indexed marketId, int256 rawRate, int256 clampedRate);
    event MaxFundingRateSet(uint256 oldRate, uint256 newRate);

    error ZeroAddress();
    error MarketNotConfigured(bytes32 marketId);
    error InvalidFundingConfig(bytes32 marketId);
    error Int256Overflow();

    constructor(address clearinghouse_, address marginAccount_, address initialAdmin) {
        if (clearinghouse_ == address(0) || marginAccount_ == address(0) || initialAdmin == address(0)) {
            revert ZeroAddress();
        }
        CLEARINGHOUSE = IFxPerpClearinghouse(clearinghouse_);
        MARGIN = IFxMarginAccount(marginAccount_);
        MARGIN_DECIMALS = IFxMarginAccount(marginAccount_).marginDecimals();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
    }

    function configureFunding(bytes32 marketId, FundingConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (marketId == bytes32(0) || !config.enabled || config.maxFundingRateBpsPerSecond == 0) {
            revert InvalidFundingConfig(marketId);
        }
        fundingConfig[marketId] = config;
        if (fundingState[marketId].lastUpdate == 0) fundingState[marketId].lastUpdate = block.timestamp;
        emit FundingConfigured(marketId, config);
    }

    function pokeFundingRate(bytes32 marketId) public whenNotPaused {
        FundingConfig memory config = fundingConfig[marketId];
        if (!config.enabled) revert MarketNotConfigured(marketId);
        FundingState storage s = fundingState[marketId];
        uint256 elapsed = block.timestamp > s.lastUpdate ? block.timestamp - s.lastUpdate : 0;
        if (elapsed != 0) {
            s.cumulativeFundingE18 += s.currentRateE18PerSecond * elapsed.toInt256();
        }

        uint256 longOi = CLEARINGHOUSE.openInterestLong(marketId);
        uint256 shortOi = CLEARINGHOUSE.openInterestShort(marketId);
        uint256 cap = CLEARINGHOUSE.maxOpenInterest(marketId);
        int256 rateBps;
        if (cap != 0 && longOi != shortOi) {
            uint256 skew = longOi > shortOi ? longOi - shortOi : shortOi - longOi;
            uint256 skewBps = skew.mulDiv(10_000, cap);
            uint256 rawRateBps = skewBps.mulDiv(config.fundingVelocityBps, 10_000);
            if (rawRateBps > config.maxFundingRateBpsPerSecond) rawRateBps = config.maxFundingRateBpsPerSecond;
            int256 signedRateBps = rawRateBps.toInt256();
            rateBps = longOi > shortOi ? signedRateBps : -signedRateBps;
        }

        int256 rateE18 = rateBps * 1e14;

        // Circuit breaker: clamp rate to [-maxAbsFundingRateE18, maxAbsFundingRateE18].
        int256 rateCap = int256(maxAbsFundingRateE18);
        if (rateE18 > rateCap || rateE18 < -rateCap) {
            int256 clampedRate = rateE18 > rateCap ? rateCap : -rateCap;
            emit FundingRateClamped(marketId, rateE18, clampedRate);
            rateE18 = clampedRate;
        }

        s.currentRateE18PerSecond = rateE18;
        s.lastUpdate = block.timestamp;
        s.currentVersion += 1;
        fundingIndex[marketId][s.currentVersion] = s.cumulativeFundingE18;
        emit FundingPoked(marketId, s.currentVersion, s.currentRateE18PerSecond, s.cumulativeFundingE18);
    }

    function settleFunding(bytes32 marketId, address trader) external whenNotPaused returns (int256 fundingPaid) {
        pokeFundingRate(marketId);
        IFxPerpClearinghouse.Position memory p = CLEARINGHOUSE.position(marketId, trader);
        int256 latest = fundingState[marketId].cumulativeFundingE18;
        int256 previous = traderFundingIndex[marketId][trader];
        traderFundingIndex[marketId][trader] = latest;
        if (p.sizeE18 == 0 || latest == previous) return 0;

        int256 deltaIndex = latest - previous;
        uint256 fundingE18 = FxPerpMath.abs(p.sizeE18).mulDiv(FxPerpMath.abs(deltaIndex), 1e18);
        uint256 fundingAtomic = FxPerpMath.scaleDecimals(fundingE18, 18, MARGIN_DECIMALS);
        if (fundingAtomic > uint256(type(int256).max)) revert Int256Overflow();

        int256 fundingSigned = fundingAtomic.toInt256();
        int256 signedFunding = deltaIndex > 0 ? fundingSigned : -fundingSigned;
        fundingPaid = p.sizeE18 > 0 ? signedFunding : -signedFunding;
        MARGIN.realizePnl(trader, -fundingPaid);
        emit FundingSettled(marketId, trader, fundingPaid);
    }

    function getFundingIndex(bytes32 marketId, uint64 version) external view returns (int256 cumulativeFundingE18) {
        return fundingIndex[marketId][version];
    }

    /// @notice Admin configures the global funding rate circuit breaker.
    function setMaxFundingRate(uint256 newMaxAbsFundingRateE18) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MaxFundingRateSet(maxAbsFundingRateE18, newMaxAbsFundingRateE18);
        maxAbsFundingRateE18 = newMaxAbsFundingRateE18;
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }
}
