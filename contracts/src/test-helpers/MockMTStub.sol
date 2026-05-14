// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockMTStub — Tenderly setCode target for the CCTP V2 MessageTransmitter.
///
/// Drop 6 of the simulator suite needs to exercise FxHubMessageReceiver's full
/// executeDeposit path without round-tripping a real CCTP attestation. The
/// receiver internally calls MESSAGE_TRANSMITTER.receiveMessage(message, attestation)
/// and expects USDC to be minted to itself. We override the deterministic
/// MessageTransmitter address (0xE737e5cE…E275) with this tiny stub via a
/// `state_objects.<addr>.code` override:
///
///   * Storage slot 0 packs (usdc | mintAmt<<160). Override it per simulation
///     to control which token is minted and how much.
///   * receiveMessage transfers `mintAmt` of `usdc` to msg.sender (the receiver),
///     returns true. The stub must also be pre-funded with `mintAmt` USDC via
///     a balance-slot override on the USDC token.
///
/// Designed for use exclusively as a setCode target — never deployed live.
contract MockMTStub {
    address public usdc;    // slot 0 low bits (20 bytes)
    uint96  public mintAmt; // slot 0 high bits (12 bytes)

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        IERC20(usdc).transfer(msg.sender, uint256(mintAmt));
        return true;
    }
}
