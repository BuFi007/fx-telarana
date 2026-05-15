// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title FxHyperlaneIntentLib
/// @notice Typed payload codec for Hyperlane spoke intents.
///
/// ┌───────────────────────────────────────────────────────────────────────┐
/// │ Spoke: FxSpokeIntentRouter                                            │
/// │   build Intent(version, action, nonce, beneficiary, market, route)     │
/// │        │                                                              │
/// │        └─► Hyperlane Mailbox.dispatch(body = abi.encode(Intent))       │
/// │                                                                       │
/// │ Hub: FxHyperlaneHubReceiver                                           │
/// │   decode body → validate spoke/route/asset/market/nonce → store intent │
/// │        │                                                              │
/// │        └─► beneficiary or trusted route executes typed Hub action      │
/// └───────────────────────────────────────────────────────────────────────┘
library FxHyperlaneIntentLib {
    uint8 internal constant VERSION = 1;

    enum Action {
        Supply,
        SupplyCollateral,
        Repay,
        Borrow
    }

    struct Intent {
        uint8 version;
        Action action;
        bytes32 nonce;
        address beneficiary;
        address inputToken;
        uint256 inputAmount;
        address loanToken;
        address collateralToken;
        address route;
    }

    function encode(Intent memory intent) internal pure returns (bytes memory) {
        return abi.encode(intent);
    }

    function decode(bytes memory data) internal pure returns (Intent memory intent) {
        intent = abi.decode(data, (Intent));
    }

    function intentId(uint32 origin, bytes32 sender, Intent memory intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(origin, sender, intent));
    }

    function isTokenFunded(Action action) internal pure returns (bool) {
        return action == Action.Supply || action == Action.SupplyCollateral || action == Action.Repay;
    }

    function requiredInputToken(Intent memory intent) internal pure returns (address) {
        if (intent.action == Action.Supply || intent.action == Action.Repay) {
            return intent.loanToken;
        }
        if (intent.action == Action.SupplyCollateral) {
            return intent.collateralToken;
        }
        return address(0);
    }
}
