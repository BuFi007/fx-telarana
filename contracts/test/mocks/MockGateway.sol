// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGatewayWallet, IGatewayMinter} from "../../src/interfaces/IGateway.sol";

/// @notice Minimal mocks for Circle Gateway used by FxGatewayHook unit tests.
///
/// MockGatewayWallet: tracks per-(token, depositor) balances and exposes a configurable
/// withdrawal delay. Mimics the real GatewayWallet's deposit/withdraw flow without
/// involving Circle's off-chain operator.
///
/// MockGatewayMinter: configurable mint that ignores the attestation payload/signature
/// (since we're testing the FxGatewayHook wrapper, not Circle's attestation verification).
/// Tests use `setMintAction` to script "next mint" behavior.

contract MockGatewayWallet is IGatewayWallet {
    using SafeERC20 for IERC20;

    mapping(address token => mapping(address depositor => uint256)) public available;
    mapping(address token => mapping(address depositor => uint256)) public withdrawing;
    mapping(address token => mapping(address depositor => uint256)) public unlockBlock;

    uint256 public withdrawalDelayBlocks = 10;

    function depositFor(address token, address depositor, uint256 value) external override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), value);
        available[token][depositor] += value;
    }

    function availableBalance(address token, address depositor) external view override returns (uint256) {
        return available[token][depositor];
    }

    function initiateWithdrawal(address token, uint256 value) external override {
        require(available[token][msg.sender] >= value, "insufficient");
        available[token][msg.sender] -= value;
        withdrawing[token][msg.sender] += value;
        unlockBlock[token][msg.sender] = block.number + withdrawalDelayBlocks;
    }

    function withdraw(address token) external override {
        require(block.number >= unlockBlock[token][msg.sender], "still locked");
        uint256 amt = withdrawing[token][msg.sender];
        withdrawing[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
    }

    function withdrawalBlock(address token, address depositor) external view override returns (uint256) {
        return unlockBlock[token][depositor];
    }
}

contract MockGatewayMinter is IGatewayMinter {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct NextMint {
        bool   set;
        bool   shouldRevert;
        uint256 amount;
        address recipient;
    }

    NextMint internal _next;

    constructor(address usdc) {
        USDC = IERC20(usdc);
    }

    /// @notice Scripts the next call to gatewayMint. Tests use this to simulate "mint X to Y" or "mint reverts".
    function setNextMint(bool shouldRevert, uint256 amount, address recipient) external {
        _next = NextMint({set: true, shouldRevert: shouldRevert, amount: amount, recipient: recipient});
    }

    function gatewayMint(bytes calldata /*attestationPayload*/, bytes calldata /*signature*/) external override {
        require(_next.set, "no scripted mint");
        NextMint memory n = _next;
        delete _next;

        if (n.shouldRevert) revert("scripted mint revert");
        if (n.amount > 0 && n.recipient != address(0)) {
            // Mint by transferring from this contract's reserve (test setup pre-funds it).
            USDC.safeTransfer(n.recipient, n.amount);
        }
    }
}
