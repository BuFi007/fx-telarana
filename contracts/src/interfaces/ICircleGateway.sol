// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title ICircleGateway
/// @notice Minimal Circle Gateway surfaces used by Telarana hub-level USDC routes.
/// @dev
/// Data flow:
///   source hub EOA/operator -> GatewayWallet.deposit/depositFor(USDC)
///   source hub EOA/operator -> sign BurnIntent offchain
///   Circle Gateway API      -> attestation + signature
///   destination hub caller  -> GatewayMinter.gatewayMint(attestation, sig)
///   Telarana hook/router    -> consume minted USDC for hub FX action
interface ICircleGatewayWallet {
    function deposit(address token, uint256 value) external;

    function depositFor(address token, address depositor, uint256 value) external;

    function addDelegate(address token, address delegate) external;

    function removeDelegate(address token, address delegate) external;

    function isAuthorizedForBalance(address token, address depositor, address addr) external view returns (bool);

    function availableBalance(address token, address depositor) external view returns (uint256);
}

interface ICircleGatewayMinter {
    function gatewayMint(bytes calldata attestationPayload, bytes calldata signature) external;
}

