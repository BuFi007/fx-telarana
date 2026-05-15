// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title Minimal Hyperlane Interfaces
/// @notice Narrow Mailbox/recipient surface used by the fx-Telaraña intent lane.
///
/// ┌──────────────────────────────────────────────────────────────┐
/// │ source app → Mailbox.dispatch(destination, recipient, body)  │
/// │                         │                                    │
/// │                         └─► destination recipient.handle(...) │
/// │                              with origin + sender metadata    │
/// └──────────────────────────────────────────────────────────────┘
interface IHyperlaneMailbox {
    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        payable
        returns (bytes32 messageId);

    function quoteDispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        view
        returns (uint256 fee);
}

interface IHyperlaneRecipient {
    function handle(uint32 origin, bytes32 sender, bytes calldata messageBody) external payable;
}

interface IInterchainSecurityModule {
    function moduleType() external view returns (uint8);

    function verify(bytes calldata metadata, bytes calldata message) external returns (bool);
}

interface ISpecifiesInterchainSecurityModule {
    function interchainSecurityModule() external view returns (IInterchainSecurityModule);
}
