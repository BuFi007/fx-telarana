// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenMessengerV2} from "../../src/interfaces/ICctp.sol";

/// @notice Mock TokenMessengerV2 for unit testing the spoke.
///         Records the last call, "burns" tokens by transferring them to itself.
contract MockTokenMessenger is ITokenMessengerV2 {
    address public localMessageTransmitterAddr;

    struct LastCall {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
        bool withHook;
    }

    LastCall public last;
    uint256 public callCount;

    constructor(address localMessageTransmitter_) {
        localMessageTransmitterAddr = localMessageTransmitter_;
    }

    function localMessageTransmitter() external view returns (address) {
        return localMessageTransmitterAddr;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external override {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        last = LastCall(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold, "", false);
        callCount++;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external override {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        last = LastCall(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold, hookData, true);
        callCount++;
    }
}
