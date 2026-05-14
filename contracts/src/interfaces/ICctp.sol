// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal local declarations of CCTP V2 surfaces.
///         The official Circle interfaces live under solc 0.7.6; we redeclare here
///         under 0.8.26 to avoid pragma incompatibility while keeping the ABI exact.
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation)
        external
        returns (bool success);

    function usedNonces(bytes32 nonce) external view returns (uint256);

    function localDomain() external view returns (uint32);
}

/// @notice Implemented by any contract that wishes to receive CCTP V2 message dispatch.
///         The destination MessageTransmitter calls one of these two methods after
///         verifying the message attestation.
interface IMessageHandlerV2 {
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool);

    function handleReceiveUnfinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool);
}
