// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title IFxHubMessageReceiver
/// @notice Arc-side endpoint for cross-chain deposits from `FxSpoke` instances.
///         Atomically composes CCTP V2 `receiveMessage` (which mints USDC to this
///         contract) with a downstream call against the FX hub (`FxMarketRegistry`
///         supply/borrow/etc.) on behalf of the original beneficiary.
///
/// If the downstream hub call reverts, the deposit is marked **stranded** and
/// anyone can sweep the funds back to the beneficiary after the grace window.
interface IFxHubMessageReceiver {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error MintRecipientMismatch(address expected, address actual);
    error AmountMismatch(uint256 expected, uint256 actual);
    error HookDataMismatch();
    error UnknownDeposit(bytes32 messageNonce);
    error AlreadyExecuted(bytes32 messageNonce);
    error NotStranded(bytes32 messageNonce);
    error GraceUnexpired(bytes32 messageNonce, uint256 strandedAt, uint256 graceEndsAt);
    error AlreadySwept(bytes32 messageNonce);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositExecuted(
        bytes32 indexed messageNonce,
        address indexed beneficiary,
        uint256 amount
    );
    event DepositStranded(
        bytes32 indexed messageNonce,
        address indexed beneficiary,
        uint256 amount,
        bytes reason
    );
    event DepositSwept(
        bytes32 indexed messageNonce,
        address indexed beneficiary,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    enum DepositState { Unknown, Executed, Stranded, Swept }

    struct StrandedDeposit {
        address beneficiary;
        uint96 amount;
        uint64 strandedAt;
        DepositState state;
    }

    function depositState(bytes32 messageNonce) external view returns (DepositState);
    function strandedDeposit(bytes32 messageNonce) external view returns (StrandedDeposit memory);

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Single-tx CCTP V2 mint + hub-call execution.
    /// @param cctpMessage     Raw CCTP V2 message (will be passed to MessageTransmitterV2).
    /// @param cctpAttestation Circle attestation signature(s) over cctpMessage.
    /// @param beneficiary     The Hub-side owner the deposit is for (must match hookData).
    /// @param hubCalldata     The action to execute against `FxMarketRegistry` (must match hookData).
    function executeDeposit(
        bytes calldata cctpMessage,
        bytes calldata cctpAttestation,
        address beneficiary,
        bytes calldata hubCalldata
    ) external;

    /// @notice Sweep a stranded deposit to its original beneficiary. Anyone, after grace.
    function sweepStrandedDeposit(bytes32 messageNonce) external;

    /// @notice Grace window (seconds) before stranded deposits can be swept.
    function STRANDED_DEPOSIT_GRACE() external view returns (uint256);
}
