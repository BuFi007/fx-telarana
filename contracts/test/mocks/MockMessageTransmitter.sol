// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMessageTransmitterV2} from "../../src/interfaces/ICctp.sol";
import {MockERC20} from "./MockERC20.sol";
import {CctpMessageLib} from "../../src/libraries/CctpMessageLib.sol";

/// @notice Mock MessageTransmitterV2 for unit testing the hub receiver.
///         `receiveMessage` mints `mintedAmount(message)` tokens of `usdc` to the recipient,
///         and tracks used nonces. Attestation bytes are ignored.
contract MockMessageTransmitter is IMessageTransmitterV2 {
    using CctpMessageLib for bytes;

    MockERC20 public usdc;
    uint32 public override localDomain;
    mapping(bytes32 => uint256) public override usedNonces;

    bool public failOnReceive;

    constructor(MockERC20 usdc_, uint32 localDomain_) {
        usdc = usdc_;
        localDomain = localDomain_;
    }

    function setFailOnReceive(bool v) external {
        failOnReceive = v;
    }

    function receiveMessage(bytes calldata message, bytes calldata /*attestation*/)
        external
        override
        returns (bool)
    {
        if (failOnReceive) return false;

        bytes32 nonce = message.nonce();
        require(usedNonces[nonce] == 0, "Nonce already used");
        usedNonces[nonce] = 1;

        address recipient = message.mintRecipient();
        uint256 amount = message.mintedAmount();

        usdc.mint(recipient, amount);
        return true;
    }
}
