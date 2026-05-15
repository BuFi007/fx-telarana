// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title IFxSpoke
/// @notice Cross-chain entrypoint to the fx-Telaraña Hub.
///
/// The same contract serves public and Ghost Mode callers:
///   * Public mode      — `msg.sender` is the user's EOA / SCA.
///   * Ghost Mode       — `msg.sender` is the Bufi Ghost router; the route's
///                        hub action/account is passed as `beneficiary`.
///
/// `beneficiary` is the Hub-side owner of the resulting position. NEVER derive it
/// from `msg.sender` server-side — routed positions would get stuck under the
/// router address.
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

    event Exited(bytes32 indexed messageNonce, address indexed recipient, address indexed token, uint256 amount);

    event Stranded(bytes32 indexed messageNonce, address indexed beneficiary, uint256 amount, bytes reason);
    event Swept(bytes32 indexed messageNonce, address indexed beneficiary, uint256 amount);
    event CircleTokenAllowedSet(address indexed token, bool allowed);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn `amount` of a Circle CCTP token (USDC or EURC only) and post
    ///         `hubCalldata` for the Hub to execute on `beneficiary`'s behalf.
    /// @param amount       Token amount to burn (must be approved to this contract).
    /// @param beneficiary  Hub-side owner of the resulting position. In Ghost
    ///                     Mode, pass the route-selected Ghost action account
    ///                     (NOT msg.sender — that's the router).
    /// @param hubCalldata  ABI-encoded call the Hub receiver should make after mint.
    /// @return messageNonce CCTP V2 nonce, useful for stranded-deposit recovery.
    function enterHub(address token, uint256 amount, address beneficiary, bytes calldata hubCalldata)
        external
        payable
        returns (bytes32 messageNonce);

    /// @notice Grant/revoke a Circle CCTP token. Intended for USDC and EURC only.
    function setCircleTokenAllowed(address token, bool allowed) external;

    /// @notice Transfer CCTP allowlist ownership to protocol governance.
    function transferOwner(address newOwner) external;

    /// @notice Receive a CCTP V2 burn from the Hub and forward minted tokens to `recipient`.
    function exitHub(bytes calldata cctpMessage, bytes calldata attestation, address recipient) external;

    /// @notice Receive a CCTP V2 burn and account for the specific local Circle token.
    function exitHubForToken(bytes calldata cctpMessage, bytes calldata attestation, address recipient, address token)
        external;
}
