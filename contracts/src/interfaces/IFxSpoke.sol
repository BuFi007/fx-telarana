// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFxSpoke
/// @notice Cross-chain entrypoint to the fx-Telaraña Hub on Arc.
///
/// The same contract serves public and confidential callers:
///   * Public mode      — `msg.sender` is the user's EOA / SCA.
///   * Confidential mode — `msg.sender` is the Hinkal Emporium relay; the user's
///                         per-deposit fresh SCA is passed as `beneficiary`.
///
/// `beneficiary` is the Hub-side owner of the resulting position. NEVER derive it
/// from `msg.sender` server-side — confidential positions would get stuck under
/// the relay address.
interface IFxSpoke {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnsupportedToken(address token);
    error InvalidBeneficiary();
    error MessageNotFound(bytes32 messageNonce);
    error MessageNotStranded(bytes32 messageNonce);
    error SweepGraceUnexpired(bytes32 messageNonce, uint256 strandedAt, uint256 graceEndsAt);
    error AlreadySwept(bytes32 messageNonce);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Entered(
        bytes32 indexed messageNonce,
        address indexed beneficiary,
        address indexed token,
        uint256 amount,
        bytes hubCalldata
    );

    event Exited(
        bytes32 indexed messageNonce,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    event Stranded(bytes32 indexed messageNonce, address indexed beneficiary, uint256 amount, bytes reason);
    event Swept(bytes32 indexed messageNonce, address indexed beneficiary, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn `amount` of `token` via CCTP V2 and post `hubCalldata` for the
    ///         Hub to execute on `beneficiary`'s behalf.
    /// @param amount       Token amount to burn (must be approved to this contract).
    /// @param beneficiary  Hub-side owner of the resulting position. Pass user SCA
    ///                     in confidential mode (NOT msg.sender — that's the relay).
    /// @param hubCalldata  ABI-encoded call the Hub receiver should make after mint.
    /// @return messageNonce CCTP V2 nonce, useful for stranded-deposit recovery.
    function enterHub(
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata hubCalldata
    ) external payable returns (bytes32 messageNonce);

    /// @notice Receive a CCTP V2 burn from Arc and forward minted tokens to `recipient`.
    function exitHub(
        bytes calldata cctpMessage,
        bytes calldata attestation,
        address recipient
    ) external;

}

