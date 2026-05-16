// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IGatewayWallet — minimal surface for Circle Gateway source-side
///
/// @notice We only need three calls into the wallet contract:
///   * `depositFor`         — push USDC into Gateway, credit a third-party authority's balance
///   * `availableBalance`   — read what's locked under our authority (off-chain monitoring helper)
///   * `initiateWithdrawal` — flag balance for the operator-delay withdrawal flow if we ever need to exit
///
/// Full Circle interface is at https://github.com/circlefin/evm-gateway-contracts.
/// We intentionally do NOT pull in their full interface — keeps our build graph free of Circle's
/// 0.8.29 pragma and minimizes surface for adversarial review.
interface IGatewayWallet {
    function depositFor(address token, address depositor, uint256 value) external;
    function availableBalance(address token, address depositor) external view returns (uint256);
    function initiateWithdrawal(address token, uint256 value) external;
    function withdraw(address token) external;
    function withdrawalBlock(address token, address depositor) external view returns (uint256);
}

/// @title IGatewayMinter — minimal surface for Circle Gateway destination-side
///
/// @notice Only one call: submit an attestation signed by Circle's `attestationSigner` to mint
/// USDC at `destinationRecipient` from the spec.
///
/// The attestation payload is byte-encoded by Circle's off-chain operator. `gatewayMint` will
/// revert if:
///   * The signature isn't from a registered attestation signer
///   * The destination domain != this minter's domain
///   * The destination contract != this minter
///   * `destinationCaller` != msg.sender (when destinationCaller != 0)
///   * The recipient is denylisted
///   * The transfer spec hash was already used (replay protection)
interface IGatewayMinter {
    function gatewayMint(bytes calldata attestationPayload, bytes calldata signature) external;
}
