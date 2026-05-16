// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFxGatewayHook — surface the local hub needs to invoke the bridge
///
/// @notice Minimal interface so FxHubMessageReceiver can call into the
/// FxGatewayHook without pulling the full hook source into its compile graph.
/// Hook is `onlyHub` for these mutating methods — the hub is the only authorized
/// caller, period. The hub then layers its own auth (owner + bufxCallers) on
/// top via `relayToRemoteHub` / `relayMintFromRemote`.
interface IFxGatewayHook {
    function lockForRemote(uint256 amount) external;
    function mintFromRemote(bytes calldata attestationPayload, bytes calldata signature)
        external
        returns (uint256 minted);
    function gatewayBalance() external view returns (uint256);
}
