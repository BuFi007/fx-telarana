// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFxOrderSettlement} from "./interfaces/IFxOrderSettlement.sol";
import {IFxPerpClearinghouse} from "./interfaces/IFxPerpClearinghouse.sol";
import {FxPerpMath} from "./FxPerpMath.sol";

/// @title FxOrderSettlement
/// @notice Keeper-settled EIP-712 maker/taker fills for the Phase E orderbook.
/// @dev References:
///      - OZ `EIP712` and `SignatureChecker` for typed-data hashing and
///        EOA/ERC-1271 signature verification.
///      - Uniswap Permit2 nonce-bitmap pattern (`nonce >> 8`, low byte bit).
///      - Synthetix v3 `AsyncOrderModule` for keeper-settled order flow.
contract FxOrderSettlement is IFxOrderSettlement, EIP712, AccessControl, Pausable, ReentrancyGuard {
    using SafeCast for uint256;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    uint8 public constant ORDER_TYPE_MARKET = 0;
    uint8 public constant ORDER_TYPE_LIMIT = 1;
    uint8 public constant FLAG_REDUCE_ONLY = 1;
    uint8 public constant FLAG_POST_ONLY = 2;

    bytes32 public constant SIGNED_ORDER_TYPEHASH = keccak256(
        "SignedOrder(address trader,bytes32 marketId,int256 sizeDeltaE18,uint256 priceE18,uint8 orderType,uint8 flags,uint64 nonce,uint64 deadline)"
    );

    IFxPerpClearinghouse public immutable CLEARINGHOUSE;
    mapping(address trader => mapping(uint256 wordPos => uint256 bitmap)) public nonceBitmap;

    event OrderCancelled(address indexed trader, uint64 nonce);
    event MatchSettled(
        bytes32 indexed marketId,
        address indexed maker,
        address indexed taker,
        uint256 fillSizeE18,
        uint256 fillPriceE18
    );

    error ZeroAddress();
    error ZeroAmount();
    error ExpiredOrder(address trader, uint64 deadline);
    error InvalidSignature(address trader);
    error InvalidOrderType(uint8 orderType);
    error InvalidMatch();
    error NonceAlreadyUsed(address trader, uint64 nonce);
    error LimitPriceExceeded(address trader, uint256 limitPriceE18, uint256 fillPriceE18);
    error ReduceOnlyViolation(address trader);
    error PostOnlyTaker();

    constructor(address clearinghouse_, address initialAdmin)
        EIP712("TelaranaFxOrderSettlement", "1")
    {
        if (clearinghouse_ == address(0) || initialAdmin == address(0)) revert ZeroAddress();
        CLEARINGHOUSE = IFxPerpClearinghouse(clearinghouse_);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
        _grantRole(SETTLER_ROLE, initialAdmin);
    }

    function settleMatch(
        SignedOrder calldata maker,
        bytes calldata makerSig,
        SignedOrder calldata taker,
        bytes calldata takerSig,
        uint256 fillSizeE18,
        uint256 fillPriceE18
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(SETTLER_ROLE)
    {
        if (fillSizeE18 == 0 || fillPriceE18 == 0) revert ZeroAmount();
        if (maker.trader == address(0) || taker.trader == address(0)) revert ZeroAddress();
        if (maker.trader == taker.trader || maker.marketId != taker.marketId) revert InvalidMatch();
        if (!_oppositeSides(maker.sizeDeltaE18, taker.sizeDeltaE18)) revert InvalidMatch();
        if (fillSizeE18 > FxPerpMath.abs(maker.sizeDeltaE18) || fillSizeE18 > FxPerpMath.abs(taker.sizeDeltaE18)) {
            revert InvalidMatch();
        }

        _validateOrder(maker, makerSig, fillPriceE18);
        _validateOrder(taker, takerSig, fillPriceE18);
        if ((taker.flags & FLAG_POST_ONLY) != 0) revert PostOnlyTaker();

        int256 fillSizeSigned = fillSizeE18.toInt256();
        int256 makerDelta = maker.sizeDeltaE18 > 0 ? fillSizeSigned : -fillSizeSigned;
        int256 takerDelta = -makerDelta;
        _validateReduceOnly(maker, makerDelta, fillSizeE18);
        _validateReduceOnly(taker, takerDelta, fillSizeE18);

        _useNonce(maker.trader, maker.nonce);
        _useNonce(taker.trader, taker.nonce);

        CLEARINGHOUSE.applyOrderFill(maker.marketId, maker.trader, makerDelta, fillPriceE18, type(uint256).max);
        CLEARINGHOUSE.applyOrderFill(taker.marketId, taker.trader, takerDelta, fillPriceE18, type(uint256).max);

        emit MatchSettled(maker.marketId, maker.trader, taker.trader, fillSizeE18, fillPriceE18);
    }

    function cancelOrder(uint64 nonce) external {
        _useNonce(msg.sender, nonce);
        emit OrderCancelled(msg.sender, nonce);
    }

    function hashOrder(SignedOrder calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    function _validateOrder(SignedOrder calldata order, bytes calldata sig, uint256 fillPriceE18) internal view {
        if (order.orderType != ORDER_TYPE_MARKET && order.orderType != ORDER_TYPE_LIMIT) {
            revert InvalidOrderType(order.orderType);
        }
        if (order.deadline < block.timestamp) revert ExpiredOrder(order.trader, order.deadline);
        if (!SignatureChecker.isValidSignatureNow(order.trader, _hashOrder(order), sig)) revert InvalidSignature(order.trader);
        if (order.orderType == ORDER_TYPE_LIMIT) {
            bool buy = order.sizeDeltaE18 > 0;
            if ((buy && fillPriceE18 > order.priceE18) || (!buy && fillPriceE18 < order.priceE18)) {
                revert LimitPriceExceeded(order.trader, order.priceE18, fillPriceE18);
            }
        }
    }

    function _validateReduceOnly(SignedOrder calldata order, int256 signedFillDelta, uint256 fillSizeE18) internal view {
        if ((order.flags & FLAG_REDUCE_ONLY) == 0) return;
        IFxPerpClearinghouse.Position memory p = CLEARINGHOUSE.position(order.marketId, order.trader);
        if (p.sizeE18 == 0 || FxPerpMath.sameSign(p.sizeE18, signedFillDelta)) revert ReduceOnlyViolation(order.trader);
        if (fillSizeE18 > FxPerpMath.abs(p.sizeE18)) revert ReduceOnlyViolation(order.trader);
    }

    function _hashOrder(SignedOrder calldata order) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_ORDER_TYPEHASH,
                order.trader,
                order.marketId,
                order.sizeDeltaE18,
                order.priceE18,
                order.orderType,
                order.flags,
                order.nonce,
                order.deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _useNonce(address trader, uint64 nonce) internal {
        uint256 wordPos = uint256(nonce) >> 8;
        uint256 bit = 2 ** (uint256(nonce) & 0xff);
        uint256 bitmap = nonceBitmap[trader][wordPos];
        if (bitmap & bit != 0) revert NonceAlreadyUsed(trader, nonce);
        nonceBitmap[trader][wordPos] = bitmap | bit;
    }

    function _oppositeSides(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b < 0) || (a < 0 && b > 0);
    }
}
