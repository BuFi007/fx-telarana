// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHyperlaneMailbox} from "../interfaces/IHyperlane.sol";
import {FxHyperlaneIntentLib} from "../libraries/FxHyperlaneIntentLib.sol";

/// @title FxSpokeIntentRouter
/// @notice Hyperlane command lane for spoke-origin FX lending intents.
///
/// ┌───────────────────────────────────────────────────────────────────────┐
/// │ user on spoke chain                                                   │
/// │   │                                                                   │
/// │   ├─► quoteIntent(...)                                                │
/// │   │      └─► Hyperlane Mailbox.quoteDispatch                          │
/// │   │                                                                   │
/// │   └─► sendIntent{value: fee}(typed action + market + route)           │
/// │          └─► Hyperlane Mailbox.dispatch → FxHyperlaneHubReceiver       │
/// │                                                                       │
/// │ Token movement is intentionally out of this contract. CCTP remains    │
/// │ canonical for USDC; Hyperlane Warp Routes can later fund non-USDC      │
/// │ hub assets, but the hub only accepts registered route assets.          │
/// └───────────────────────────────────────────────────────────────────────┘
contract FxSpokeIntentRouter is ReentrancyGuard {
    IHyperlaneMailbox public immutable MAILBOX;
    uint32 public immutable LOCAL_DOMAIN;
    uint32 public immutable HUB_DOMAIN;
    bytes32 public immutable HUB_RECEIVER;

    uint64 public nextNonce = 1;

    error ZeroAddress();
    error InvalidAction(uint8 action);
    error InvalidIntent();
    error FeeTooLow(uint256 required, uint256 provided);
    error RefundFailed();

    event IntentDispatched(
        bytes32 indexed intentId,
        bytes32 indexed messageId,
        address indexed sender,
        address beneficiary,
        uint32 localDomain,
        uint32 hubDomain,
        FxHyperlaneIntentLib.Action action,
        address inputToken,
        uint256 inputAmount,
        address loanToken,
        address collateralToken,
        address route,
        bytes32 nonce
    );

    constructor(address mailbox_, uint32 localDomain_, uint32 hubDomain_, bytes32 hubReceiver_) {
        if (mailbox_ == address(0) || hubReceiver_ == bytes32(0)) revert ZeroAddress();
        MAILBOX = IHyperlaneMailbox(mailbox_);
        LOCAL_DOMAIN = localDomain_;
        HUB_DOMAIN = hubDomain_;
        HUB_RECEIVER = hubReceiver_;
    }

    receive() external payable {}

    function quoteIntent(
        uint8 action,
        address beneficiary,
        address inputToken,
        uint256 inputAmount,
        address loanToken,
        address collateralToken,
        address route
    ) external view returns (uint256 fee) {
        bytes32 nonce = _nonceFor(msg.sender, nextNonce);
        FxHyperlaneIntentLib.Intent memory intent =
            _buildIntent(action, nonce, beneficiary, inputToken, inputAmount, loanToken, collateralToken, route);
        fee = MAILBOX.quoteDispatch(HUB_DOMAIN, HUB_RECEIVER, FxHyperlaneIntentLib.encode(intent));
    }

    function sendIntent(
        uint8 action,
        address beneficiary,
        address inputToken,
        uint256 inputAmount,
        address loanToken,
        address collateralToken,
        address route
    ) external payable nonReentrant returns (bytes32 intentId, bytes32 messageId) {
        bytes32 nonce = _nonceFor(msg.sender, nextNonce++);
        FxHyperlaneIntentLib.Intent memory intent =
            _buildIntent(action, nonce, beneficiary, inputToken, inputAmount, loanToken, collateralToken, route);
        bytes memory body = FxHyperlaneIntentLib.encode(intent);

        uint256 fee = MAILBOX.quoteDispatch(HUB_DOMAIN, HUB_RECEIVER, body);
        if (msg.value < fee) revert FeeTooLow(fee, msg.value);

        messageId = MAILBOX.dispatch{value: fee}(HUB_DOMAIN, HUB_RECEIVER, body);
        intentId = FxHyperlaneIntentLib.intentId(LOCAL_DOMAIN, _addressToBytes32(address(this)), intent);

        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            if (!ok) revert RefundFailed();
        }

        emit IntentDispatched(
            intentId,
            messageId,
            msg.sender,
            beneficiary,
            LOCAL_DOMAIN,
            HUB_DOMAIN,
            intent.action,
            inputToken,
            inputAmount,
            loanToken,
            collateralToken,
            route,
            nonce
        );
    }

    function _buildIntent(
        uint8 action,
        bytes32 nonce,
        address beneficiary,
        address inputToken,
        uint256 inputAmount,
        address loanToken,
        address collateralToken,
        address route
    ) internal pure returns (FxHyperlaneIntentLib.Intent memory intent) {
        if (action > uint8(FxHyperlaneIntentLib.Action.Borrow)) revert InvalidAction(action);
        if (beneficiary == address(0) || loanToken == address(0) || collateralToken == address(0)) {
            revert ZeroAddress();
        }

        intent = FxHyperlaneIntentLib.Intent({
            version: FxHyperlaneIntentLib.VERSION,
            action: FxHyperlaneIntentLib.Action(action),
            nonce: nonce,
            beneficiary: beneficiary,
            inputToken: inputToken,
            inputAmount: inputAmount,
            loanToken: loanToken,
            collateralToken: collateralToken,
            route: route
        });

        if (FxHyperlaneIntentLib.isTokenFunded(intent.action)) {
            if (inputAmount == 0 || route == address(0)) revert InvalidIntent();
            if (inputToken != FxHyperlaneIntentLib.requiredInputToken(intent)) revert InvalidIntent();
        } else {
            if (inputToken != address(0) || inputAmount != 0 || route != address(0)) revert InvalidIntent();
        }
    }

    function _nonceFor(address sender, uint64 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, nonce));
    }

    function _addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
