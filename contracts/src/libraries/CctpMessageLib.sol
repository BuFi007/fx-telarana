// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Decodes CCTP V2 message and burn-message-body byte layouts.
///
/// CCTP V2 outer message format:
///   Field                       Bytes   Type      Offset
///   version                     4       uint32    0
///   sourceDomain                4       uint32    4
///   destinationDomain           4       uint32    8
///   nonce                       32      bytes32   12
///   sender                      32      bytes32   44
///   recipient                   32      bytes32   76
///   destinationCaller           32      bytes32   108
///   minFinalityThreshold        4       uint32    140
///   finalityThresholdExecuted   4       uint32    144
///   messageBody                 dyn     bytes     148
///
/// CCTP V2 BurnMessage body format:
///   Field           Bytes   Type      Offset
///   version         4       uint32    0
///   burnToken       32      bytes32   4
///   mintRecipient   32      bytes32   36
///   amount          32      uint256   68
///   messageSender   32      bytes32   100
///   maxFee          32      uint256   132
///   feeExecuted     32      uint256   164
///   expirationBlock 32      uint256   196
///   hookData        dyn     bytes     228
library CctpMessageLib {
    uint256 internal constant OUTER_NONCE_OFFSET = 12;
    uint256 internal constant OUTER_RECIPIENT_OFFSET = 76;
    uint256 internal constant OUTER_BODY_OFFSET = 148;

    uint256 internal constant BURN_AMOUNT_OFFSET = 68;
    uint256 internal constant BURN_MINT_RECIPIENT_OFFSET = 36;
    uint256 internal constant BURN_FEE_EXECUTED_OFFSET = 164;
    uint256 internal constant BURN_HOOK_DATA_OFFSET = 228;

    error MessageTooShort(uint256 length, uint256 minRequired);

    /// @notice Read the outer-message nonce (bytes32 at offset 12).
    function nonce(bytes calldata message) internal pure returns (bytes32 _nonce) {
        if (message.length < OUTER_BODY_OFFSET) revert MessageTooShort(message.length, OUTER_BODY_OFFSET);
        assembly {
            _nonce := calldataload(add(message.offset, OUTER_NONCE_OFFSET))
        }
    }

    /// @notice Read the outer-message recipient (mintRecipient is in the inner body).
    function outerRecipient(bytes calldata message) internal pure returns (address) {
        if (message.length < OUTER_BODY_OFFSET) revert MessageTooShort(message.length, OUTER_BODY_OFFSET);
        bytes32 raw;
        assembly {
            raw := calldataload(add(message.offset, OUTER_RECIPIENT_OFFSET))
        }
        return address(uint160(uint256(raw)));
    }

    /// @notice Read the inner mintRecipient from a CCTP V2 burn message body inside an outer message.
    function mintRecipient(bytes calldata message) internal pure returns (address) {
        uint256 bodyStart = OUTER_BODY_OFFSET;
        uint256 fieldOffset = bodyStart + BURN_MINT_RECIPIENT_OFFSET;
        if (message.length < fieldOffset + 32) revert MessageTooShort(message.length, fieldOffset + 32);
        bytes32 raw;
        assembly {
            raw := calldataload(add(message.offset, fieldOffset))
        }
        return address(uint160(uint256(raw)));
    }

    /// @notice Read the burn amount (before fee deduction).
    function burnAmount(bytes calldata message) internal pure returns (uint256 amount) {
        uint256 fieldOffset = OUTER_BODY_OFFSET + BURN_AMOUNT_OFFSET;
        if (message.length < fieldOffset + 32) revert MessageTooShort(message.length, fieldOffset + 32);
        assembly {
            amount := calldataload(add(message.offset, fieldOffset))
        }
    }

    /// @notice Read the fee executed (subtracted from burnAmount at mint).
    function feeExecuted(bytes calldata message) internal pure returns (uint256 fee) {
        uint256 fieldOffset = OUTER_BODY_OFFSET + BURN_FEE_EXECUTED_OFFSET;
        if (message.length < fieldOffset + 32) revert MessageTooShort(message.length, fieldOffset + 32);
        assembly {
            fee := calldataload(add(message.offset, fieldOffset))
        }
    }

    /// @notice Net amount minted on the destination = burnAmount - feeExecuted.
    function mintedAmount(bytes calldata message) internal pure returns (uint256) {
        return burnAmount(message) - feeExecuted(message);
    }

    /// @notice Extract the hookData appended to the burn message body.
    function hookData(bytes calldata message) internal pure returns (bytes memory) {
        uint256 start = OUTER_BODY_OFFSET + BURN_HOOK_DATA_OFFSET;
        if (message.length < start) revert MessageTooShort(message.length, start);
        uint256 len = message.length - start;
        bytes memory out = new bytes(len);
        if (len > 0) {
            assembly {
                calldatacopy(add(out, 32), add(message.offset, start), len)
            }
        }
        return out;
    }
}
