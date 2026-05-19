// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";
import {IFxFundingEngine} from "./interfaces/IFxFundingEngine.sol";
import {IFxMarginAccount} from "./interfaces/IFxMarginAccount.sol";
import {IFxPerpClearinghouse} from "./interfaces/IFxPerpClearinghouse.sol";
import {FxPerpMath} from "./FxPerpMath.sol";

/// @title FxPerpClearinghouse
/// @notice USDC-margined FX perp lifecycle for Phase B-E testnet wiring.
/// @dev Reference shape:
///      - Position lifecycle and OI accounting mirror GMX Synthetics
///        `IncreasePositionUtils` / `DecreasePositionUtils` / `PositionUtils`.
///      - Margin requirement is a thin ratio wrapper over the Synthetix v3 BFP
///        initial-margin pattern.
///      - The oracle-version accumulator model is intentionally isolated in
///        `FxFundingEngine`, following Perennial v2's version-keyed pattern.
contract FxPerpClearinghouse is IFxPerpClearinghouse, AccessControl, Pausable, ReentrancyGuard {
    using Math for uint256;
    using SafeCast for uint256;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant ORDER_SETTLEMENT_ROLE = keccak256("ORDER_SETTLEMENT_ROLE");
    bytes32 public constant LIQUIDATION_ENGINE_ROLE = keccak256("LIQUIDATION_ENGINE_ROLE");

    address public immutable USDC;
    IFxOracle public immutable ORACLE;
    IFxMarginAccount private immutable MARGIN_ACCOUNT;
    uint8 public immutable MARGIN_DECIMALS;
    address public fundingEngine;

    mapping(bytes32 marketId => MarketConfig config) private _marketConfig;
    mapping(bytes32 marketId => bool configured) private _marketConfigured;
    mapping(bytes32 marketId => mapping(address trader => Position position)) private _position;
    bytes32[] private _marketIds;
    mapping(bytes32 marketId => uint256 amount) public openInterestLong;
    mapping(bytes32 marketId => uint256 amount) public openInterestShort;

    event MarketConfigured(bytes32 indexed marketId, MarketConfig config);
    event FundingEngineSet(address indexed fundingEngine);
    event PositionIncreased(
        bytes32 indexed marketId,
        address indexed trader,
        int256 sizeDeltaE18,
        int256 resultingSizeE18,
        uint256 entryPriceE18,
        uint256 marginReserved,
        uint256 fee
    );
    event PositionDecreased(
        bytes32 indexed marketId,
        address indexed trader,
        int256 sizeDeltaE18,
        int256 resultingSizeE18,
        uint256 priceE18,
        uint256 marginReleased,
        int256 pnl,
        uint256 badDebt
    );
    event BadDebtSocialized(bytes32 indexed marketId, address indexed trader, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error MarketNotEnabled(bytes32 marketId);
    error InvalidMarketConfig(bytes32 marketId);
    error InvalidPositionDelta(int256 currentSizeE18, int256 sizeDeltaE18);
    error PositionNotFound(bytes32 marketId, address trader);
    error SlippageFeeExceeded(uint256 fee, uint256 maxFee);
    error OpenInterestCapExceeded(bytes32 marketId, uint256 nextOpenInterest, uint256 cap);
    error SkewCapExceeded(bytes32 marketId, uint256 nextSkew, uint256 cap);
    error Int256Overflow();
    error FundingEngineNotSet();
    error InvalidFundingEngine(address fundingEngine);

    constructor(address usdc_, address oracle_, address marginAccount_, address initialAdmin) {
        if (usdc_ == address(0) || oracle_ == address(0) || marginAccount_ == address(0) || initialAdmin == address(0))
        {
            revert ZeroAddress();
        }
        USDC = usdc_;
        ORACLE = IFxOracle(oracle_);
        MARGIN_ACCOUNT = IFxMarginAccount(marginAccount_);
        MARGIN_DECIMALS = IFxMarginAccount(marginAccount_).marginDecimals();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
        _grantRole(EXECUTOR_ROLE, initialAdmin);
    }

    function configureMarket(bytes32 marketId, MarketConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateMarketConfig(marketId, config);
        if (!_marketConfigured[marketId]) {
            _marketConfigured[marketId] = true;
            _marketIds.push(marketId);
        }
        _marketConfig[marketId] = config;
        emit MarketConfigured(marketId, config);
    }

    function setFundingEngine(address fundingEngine_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fundingEngine_ == address(0) || fundingEngine_.code.length == 0) {
            revert InvalidFundingEngine(fundingEngine_);
        }
        IFxFundingEngine engine = IFxFundingEngine(fundingEngine_);
        if (address(engine.CLEARINGHOUSE()) != address(this) || address(engine.MARGIN()) != address(MARGIN_ACCOUNT)) {
            revert InvalidFundingEngine(fundingEngine_);
        }
        fundingEngine = fundingEngine_;
        emit FundingEngineSet(fundingEngine_);
    }

    function openOrIncrease(bytes32 marketId, address trader, int256 sizeDeltaE18, uint256 maxFee)
        external
        whenNotPaused
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
        returns (bytes32 positionKey)
    {
        _settleFunding(marketId, trader);
        uint256 priceE18 = _price(marketId);
        positionKey = _applyIncrease(marketId, trader, sizeDeltaE18, priceE18, maxFee);
    }

    function decreaseOrClose(bytes32 marketId, address trader, int256 sizeDeltaE18)
        external
        whenNotPaused
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
        returns (uint256 marginReleased)
    {
        _settleFunding(marketId, trader);
        uint256 priceE18 = _price(marketId);
        (marginReleased,,) = _applyDecrease(marketId, trader, sizeDeltaE18, priceE18);
    }

    function applyOrderFill(bytes32 marketId, address trader, int256 sizeDeltaE18, uint256 fillPriceE18, uint256 maxFee)
        external
        whenNotPaused
        nonReentrant
        onlyRole(ORDER_SETTLEMENT_ROLE)
        returns (bytes32 positionKey)
    {
        if (fillPriceE18 == 0) revert ZeroAmount();
        _settleFunding(marketId, trader);
        Position memory p = _position[marketId][trader];
        if (p.sizeE18 != 0 && !FxPerpMath.sameSign(p.sizeE18, sizeDeltaE18)) {
            (, positionKey,) = _applyDecreaseOrFlip(marketId, trader, sizeDeltaE18, fillPriceE18, maxFee);
        } else {
            positionKey = _applyIncrease(marketId, trader, sizeDeltaE18, fillPriceE18, maxFee);
        }
    }

    function liquidatePosition(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        whenNotPaused
        nonReentrant
        onlyRole(LIQUIDATION_ENGINE_ROLE)
        returns (uint256 marginReleased, int256 pnl, uint256 badDebt)
    {
        if (maxSizeToCloseAbsE18 == 0) revert ZeroAmount();
        _settleFunding(marketId, trader);
        Position memory p = _position[marketId][trader];
        if (p.sizeE18 == 0) revert PositionNotFound(marketId, trader);
        uint256 closeAbs = FxPerpMath.abs(p.sizeE18);
        if (maxSizeToCloseAbsE18 < closeAbs) closeAbs = maxSizeToCloseAbsE18;
        int256 closeAbsSigned = closeAbs.toInt256();
        int256 closeDelta = p.sizeE18 > 0 ? -closeAbsSigned : closeAbsSigned;
        // Codex contract review P1 #1: liquidation uses the strict
        // deviation-gated price. Caller (FxLiquidationEngine) MUST wrap
        // the tx with the RedStone SDK so the signed payload is in
        // calldata tail. Same pattern the keeper SDK uses for
        // FxGatewayHook.
        uint256 priceE18 = _priceVerified(marketId);
        (marginReleased, pnl, badDebt) = _applyDecrease(marketId, trader, closeDelta, priceE18);
    }

    function quoteFee(bytes32 marketId, address, int256 sizeDeltaE18)
        external
        view
        returns (uint256 feeAmount, uint256 priceE18)
    {
        MarketConfig memory config = _enabledMarket(marketId);
        priceE18 = _priceView(config);
        uint256 notional = FxPerpMath.notionalFromSize(FxPerpMath.abs(sizeDeltaE18), priceE18, MARGIN_DECIMALS);
        feeAmount = FxPerpMath.fee(notional, config.tradingFeeBps);
    }

    function unrealizedPnl(bytes32 marketId, address trader) public view returns (int256 pnlAmount) {
        MarketConfig memory config = _enabledMarket(marketId);
        Position memory p = _position[marketId][trader];
        if (p.sizeE18 == 0) return 0;
        uint256 priceE18 = _priceView(config);
        return FxPerpMath.pnl(p.sizeE18, p.entryPriceE18, priceE18, MARGIN_DECIMALS);
    }

    /// @inheritdoc IFxPerpClearinghouse
    // Codex contract review P1 #1: the lenient unrealizedPnl path uses
    // ORACLE.getMid (Pyth-first with no two-source agreement gate). A
    // brief Pyth manipulation while RedStone disagrees would be enough
    // to compute PnL for a wrongful liquidation. This sibling reads the
    // strict deviation-gated path so liquidator + verified-health
    // callers can trust the result. Off-chain monitoring still reads
    // the lenient `unrealizedPnl` (no RedStone payload needed in
    // calldata).
    function unrealizedPnlVerified(bytes32 marketId, address trader) public view returns (int256 pnlAmount) {
        MarketConfig memory config = _enabledMarket(marketId);
        Position memory p = _position[marketId][trader];
        if (p.sizeE18 == 0) return 0;
        uint256 priceE18 = _priceViewVerified(config);
        return FxPerpMath.pnl(p.sizeE18, p.entryPriceE18, priceE18, MARGIN_DECIMALS);
    }

    function position(bytes32 marketId, address trader) public view returns (Position memory) {
        return _position[marketId][trader];
    }

    function marketConfig(bytes32 marketId) public view returns (MarketConfig memory) {
        return _marketConfig[marketId];
    }

    function marginAccount() external view returns (address) {
        return address(MARGIN_ACCOUNT);
    }

    function marketIdCount() external view returns (uint256) {
        return _marketIds.length;
    }

    function marketIdAt(uint256 index) external view returns (bytes32) {
        return _marketIds[index];
    }

    function maxOpenInterest(bytes32 marketId) external view returns (uint256) {
        return _marketConfig[marketId].maxOpenInterestUsd;
    }

    function settleTraderFunding(address trader) external nonReentrant returns (int256 fundingPaid) {
        if (trader == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < _marketIds.length; i++) {
            bytes32 marketId = _marketIds[i];
            if (_position[marketId][trader].sizeE18 != 0) {
                fundingPaid += _settleFunding(marketId, trader);
            }
        }
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    function _applyIncrease(bytes32 marketId, address trader, int256 sizeDeltaE18, uint256 fillPriceE18, uint256 maxFee)
        internal
        returns (bytes32 positionKey)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (sizeDeltaE18 == 0) revert ZeroAmount();
        MarketConfig memory config = _enabledMarket(marketId);
        Position storage p = _position[marketId][trader];
        if (p.sizeE18 != 0 && !FxPerpMath.sameSign(p.sizeE18, sizeDeltaE18)) {
            revert InvalidPositionDelta(p.sizeE18, sizeDeltaE18);
        }

        uint256 deltaAbs = FxPerpMath.abs(sizeDeltaE18);
        uint256 notional = FxPerpMath.notionalFromSize(deltaAbs, fillPriceE18, MARGIN_DECIMALS);
        uint256 feeAmount = FxPerpMath.fee(notional, config.tradingFeeBps);
        if (feeAmount > maxFee) revert SlippageFeeExceeded(feeAmount, maxFee);
        uint256 required = FxPerpMath.requiredMargin(notional, config.initialMarginBps);

        _assertOiCaps(marketId, config, sizeDeltaE18, notional, true);

        if (feeAmount != 0) {
            _realizeFee(trader, feeAmount);
        }
        MARGIN_ACCOUNT.reserveMargin(trader, required);

        p.entryPriceE18 = FxPerpMath.weightedEntryPrice(p.sizeE18, p.entryPriceE18, sizeDeltaE18, fillPriceE18);
        p.sizeE18 += sizeDeltaE18;
        p.marginReserved += required;

        if (sizeDeltaE18 > 0) openInterestLong[marketId] += notional;
        else openInterestShort[marketId] += notional;

        positionKey = keccak256(abi.encode(marketId, trader));
        emit PositionIncreased(marketId, trader, sizeDeltaE18, p.sizeE18, p.entryPriceE18, p.marginReserved, feeAmount);
    }

    function _applyDecreaseOrFlip(
        bytes32 marketId,
        address trader,
        int256 sizeDeltaE18,
        uint256 fillPriceE18,
        uint256 maxFee
    ) internal returns (uint256 marginReleased, bytes32 positionKey, uint256 badDebt) {
        Position memory beforePosition = _position[marketId][trader];
        uint256 currentAbs = FxPerpMath.abs(beforePosition.sizeE18);
        uint256 deltaAbs = FxPerpMath.abs(sizeDeltaE18);
        if (deltaAbs <= currentAbs) {
            (marginReleased,, badDebt) = _applyDecrease(marketId, trader, sizeDeltaE18, fillPriceE18);
            return (marginReleased, keccak256(abi.encode(marketId, trader)), badDebt);
        }

        int256 currentAbsSigned = currentAbs.toInt256();
        int256 closeDelta = beforePosition.sizeE18 > 0 ? -currentAbsSigned : currentAbsSigned;
        (marginReleased,, badDebt) = _applyDecrease(marketId, trader, closeDelta, fillPriceE18);
        int256 openRemainderSigned = (deltaAbs - currentAbs).toInt256();
        int256 openRemainder = beforePosition.sizeE18 > 0 ? -openRemainderSigned : openRemainderSigned;
        positionKey = _applyIncrease(marketId, trader, openRemainder, fillPriceE18, maxFee);
    }

    function _applyDecrease(bytes32 marketId, address trader, int256 sizeDeltaE18, uint256 fillPriceE18)
        internal
        returns (uint256 marginReleased, int256 pnlAmount, uint256 badDebt)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (sizeDeltaE18 == 0) revert ZeroAmount();
        _enabledMarket(marketId);
        Position storage p = _position[marketId][trader];
        if (p.sizeE18 == 0) revert PositionNotFound(marketId, trader);
        if (FxPerpMath.sameSign(p.sizeE18, sizeDeltaE18)) revert InvalidPositionDelta(p.sizeE18, sizeDeltaE18);

        uint256 currentAbs = FxPerpMath.abs(p.sizeE18);
        uint256 closeAbs = FxPerpMath.abs(sizeDeltaE18);
        if (closeAbs > currentAbs) revert InvalidPositionDelta(p.sizeE18, sizeDeltaE18);

        int256 closeAbsSigned = closeAbs.toInt256();
        int256 closedSignedSize = p.sizeE18 > 0 ? closeAbsSigned : -closeAbsSigned;
        uint256 oiReduction = FxPerpMath.notionalFromSize(closeAbs, p.entryPriceE18, MARGIN_DECIMALS);
        marginReleased = p.marginReserved.mulDiv(closeAbs, currentAbs);
        pnlAmount = FxPerpMath.pnl(closedSignedSize, p.entryPriceE18, fillPriceE18, MARGIN_DECIMALS);

        MARGIN_ACCOUNT.releaseMargin(trader, marginReleased);
        badDebt = MARGIN_ACCOUNT.realizePnl(trader, pnlAmount);
        if (badDebt != 0) emit BadDebtSocialized(marketId, trader, badDebt);

        p.marginReserved -= marginReleased;
        p.sizeE18 -= closedSignedSize;
        if (p.sizeE18 == 0) {
            p.entryPriceE18 = 0;
            p.marginReserved = 0;
        }

        if (closedSignedSize > 0) {
            openInterestLong[marketId] =
                oiReduction > openInterestLong[marketId] ? 0 : openInterestLong[marketId] - oiReduction;
        } else {
            openInterestShort[marketId] =
                oiReduction > openInterestShort[marketId] ? 0 : openInterestShort[marketId] - oiReduction;
        }

        emit PositionDecreased(
            marketId, trader, sizeDeltaE18, p.sizeE18, fillPriceE18, marginReleased, pnlAmount, badDebt
        );
    }

    function _realizeFee(address trader, uint256 feeAmount) internal {
        if (feeAmount > uint256(type(int256).max)) revert Int256Overflow();
        MARGIN_ACCOUNT.realizePnl(trader, -feeAmount.toInt256());
    }

    function _settleFunding(bytes32 marketId, address trader) internal returns (int256 fundingPaid) {
        if (trader == address(0)) revert ZeroAddress();
        address engine = fundingEngine;
        if (engine == address(0)) revert FundingEngineNotSet();
        return IFxFundingEngine(engine).settleFunding(marketId, trader);
    }

    function _assertOiCaps(
        bytes32 marketId,
        MarketConfig memory config,
        int256 sizeDeltaE18,
        uint256 notional,
        bool increasing
    ) internal view {
        uint256 longOi = openInterestLong[marketId];
        uint256 shortOi = openInterestShort[marketId];
        if (increasing) {
            if (sizeDeltaE18 > 0) longOi += notional;
            else shortOi += notional;
        }
        uint256 larger = longOi > shortOi ? longOi : shortOi;
        if (larger > config.maxOpenInterestUsd) {
            revert OpenInterestCapExceeded(marketId, larger, config.maxOpenInterestUsd);
        }
        uint256 skew = longOi > shortOi ? longOi - shortOi : shortOi - longOi;
        if (config.maxSkewUsd != 0 && skew > config.maxSkewUsd) {
            revert SkewCapExceeded(marketId, skew, config.maxSkewUsd);
        }
    }

    function _enabledMarket(bytes32 marketId) internal view returns (MarketConfig memory config) {
        config = _marketConfig[marketId];
        if (!config.enabled) revert MarketNotEnabled(marketId);
    }

    function _price(bytes32 marketId) internal view returns (uint256 priceE18) {
        MarketConfig memory config = _enabledMarket(marketId);
        return _priceView(config);
    }

    function _priceView(MarketConfig memory config) internal view returns (uint256 priceE18) {
        (priceE18,) = ORACLE.getMid(config.baseToken, USDC);
    }

    /// Verified-price counterparts. Use `ORACLE.getMidVerified`, which
    /// reads RedStone signed payload from msg.data tail and enforces a
    /// deviation gate against Pyth. Reserved for liquidation + PnL
    /// realization where a Pyth flicker would otherwise be exploitable
    /// (codex contract review P1 #1).
    function _priceVerified(bytes32 marketId) internal view returns (uint256 priceE18) {
        MarketConfig memory config = _enabledMarket(marketId);
        return _priceViewVerified(config);
    }

    function _priceViewVerified(MarketConfig memory config) internal view returns (uint256 priceE18) {
        (priceE18,) = ORACLE.getMidVerified(config.baseToken, USDC);
    }

    function _validateMarketConfig(bytes32 marketId, MarketConfig calldata config) internal pure {
        if (
            marketId == bytes32(0) || config.baseToken == address(0) || !config.enabled || config.initialMarginBps == 0
                || config.maintenanceMarginBps == 0 || config.maintenanceMarginBps > config.initialMarginBps
                || config.tradingFeeBps > 1_000 || config.maxLeverageBps < 10_000 || config.maxOpenInterestUsd == 0
        ) revert InvalidMarketConfig(marketId);

        uint256 minMarginBps = uint256(10_000).mulDiv(10_000, config.maxLeverageBps);
        if (config.initialMarginBps < minMarginBps) revert InvalidMarketConfig(marketId);
        if (config.maxSkewUsd > config.maxOpenInterestUsd) revert InvalidMarketConfig(marketId);
    }
}
