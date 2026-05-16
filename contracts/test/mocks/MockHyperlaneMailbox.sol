// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IHyperlaneMailbox, IHyperlaneRecipient} from "../../src/interfaces/IHyperlane.sol";

contract MockHyperlaneMailbox is IHyperlaneMailbox {
    uint256 public quote = 0.01 ether;
    uint256 public dispatchCount;

    uint32 public lastDestinationDomain;
    bytes32 public lastRecipient;
    bytes public lastBody;
    address public lastSender;
    uint256 public lastValue;

    event Dispatch(
        bytes32 indexed messageId,
        address indexed sender,
        uint32 indexed destinationDomain,
        bytes32 recipient,
        bytes body,
        uint256 value
    );

    function setQuote(uint256 quote_) external {
        quote = quote_;
    }

    function quoteDispatch(uint32, bytes32, bytes calldata) external view returns (uint256 fee) {
        return quote;
    }

    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        payable
        returns (bytes32 messageId)
    {
        lastDestinationDomain = destinationDomain;
        lastRecipient = recipientAddress;
        lastBody = messageBody;
        lastSender = msg.sender;
        lastValue = msg.value;
        messageId = keccak256(abi.encode(destinationDomain, recipientAddress, messageBody, msg.sender, dispatchCount++));
        emit Dispatch(messageId, msg.sender, destinationDomain, recipientAddress, messageBody, msg.value);
    }

    function deliver(address recipient, uint32 origin, bytes32 sender, bytes calldata messageBody) external {
        IHyperlaneRecipient(recipient).handle(origin, sender, messageBody);
    }
}
