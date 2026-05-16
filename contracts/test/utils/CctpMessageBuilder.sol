// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @notice Helper to assemble bytes matching the CCTP V2 outer-message + BurnMessage layout
///         used by `CctpMessageLib`. For unit tests only.
library CctpMessageBuilder {
    /// @notice Build a finalized CCTP V2 message with a BurnMessage body + hookData.
    function build(
        bytes32 nonce,
        address mintRecipient,
        uint256 amount,
        uint256 feeExecuted,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        // Outer message header (148 bytes)
        bytes memory header = abi.encodePacked(
            uint32(1),                                  // version
            uint32(0),                                  // sourceDomain
            uint32(26),                                 // destinationDomain (Arc)
            nonce,                                      // nonce (bytes32)
            bytes32(0),                                 // sender (filler)
            bytes32(0),                                 // recipient (filler — TokenMessengerV2 on prod)
            bytes32(0),                                 // destinationCaller (filler)
            uint32(2000),                               // minFinalityThreshold
            uint32(2000)                                // finalityThresholdExecuted
        );

        // BurnMessage body (228 bytes header + hookData)
        bytes memory body = abi.encodePacked(
            uint32(1),                                  // body version
            bytes32(0),                                 // burnToken
            bytes32(uint256(uint160(mintRecipient))),   // mintRecipient (address as bytes32)
            amount,                                     // amount (uint256)
            bytes32(0),                                 // messageSender
            uint256(0),                                 // maxFee
            feeExecuted,                                // feeExecuted
            uint256(0)                                  // expirationBlock
        );

        return abi.encodePacked(header, body, hookData);
    }
}
