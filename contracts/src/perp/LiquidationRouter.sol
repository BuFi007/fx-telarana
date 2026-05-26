// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ProxyConnector} from "@redstone-finance/evm-connector/core/ProxyConnector.sol";

import {IFxLiquidationEngine} from "./interfaces/IFxLiquidationEngine.sol";

interface ILiquidationRouterEngine is IFxLiquidationEngine {
    function flaggedAt(bytes32 marketId, address trader) external view returns (uint256);
}

/// @title LiquidationRouter
/// @notice Keeper-facing router that combines flag + liquidation attempts.
/// @dev The live liquidation engine uses RedStone's calldata-tail payload.
///      Calls to the engine must therefore go through ProxyConnector so the
///      same payload attached to the router call is forwarded downstream. If
///      the engine enforces a nonzero flag delay, fresh flags still observe
///      that delay; already-ready flags are liquidated without being reset.
contract LiquidationRouter is ProxyConnector, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ILiquidationRouterEngine public immutable engine;
    IERC20 public immutable rewardToken;

    error ZeroAddress();
    error ZeroAmount();
    error LengthMismatch();

    event AtomicLiquidation(
        bytes32 indexed marketId,
        address indexed trader,
        address indexed keeper,
        address rewardRecipient,
        bool flaggedInCall,
        uint256 liquidatorReward,
        int256 socializedLoss,
        uint256 rewardForwarded
    );

    constructor(address engine_, address rewardToken_) {
        if (engine_ == address(0) || rewardToken_ == address(0)) revert ZeroAddress();
        engine = ILiquidationRouterEngine(engine_);
        rewardToken = IERC20(rewardToken_);
    }

    function liquidateAtomic(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18)
        external
        nonReentrant
        returns (uint256 liquidatorReward, int256 socializedLoss, uint256 rewardForwarded)
    {
        return _liquidateAtomicTo(marketId, trader, maxSizeToCloseAbsE18, msg.sender);
    }

    function liquidateAtomicTo(
        bytes32 marketId,
        address trader,
        uint256 maxSizeToCloseAbsE18,
        address rewardRecipient
    ) external nonReentrant returns (uint256 liquidatorReward, int256 socializedLoss, uint256 rewardForwarded) {
        return _liquidateAtomicTo(marketId, trader, maxSizeToCloseAbsE18, rewardRecipient);
    }

    function liquidateBatch(
        bytes32[] calldata marketIds,
        address[] calldata traders,
        uint256[] calldata maxSizeToCloseAbsE18
    )
        external
        nonReentrant
        returns (uint256[] memory liquidatorRewards, int256[] memory socializedLosses, uint256[] memory rewardsForwarded)
    {
        uint256 length = marketIds.length;
        if (length != traders.length || length != maxSizeToCloseAbsE18.length) revert LengthMismatch();

        liquidatorRewards = new uint256[](length);
        socializedLosses = new int256[](length);
        rewardsForwarded = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            (liquidatorRewards[i], socializedLosses[i], rewardsForwarded[i]) =
                _liquidateAtomicTo(marketIds[i], traders[i], maxSizeToCloseAbsE18[i], msg.sender);
        }
    }

    function _liquidateAtomicTo(
        bytes32 marketId,
        address trader,
        uint256 maxSizeToCloseAbsE18,
        address rewardRecipient
    ) internal returns (uint256 liquidatorReward, int256 socializedLoss, uint256 rewardForwarded) {
        if (trader == address(0) || rewardRecipient == address(0)) revert ZeroAddress();
        if (maxSizeToCloseAbsE18 == 0) revert ZeroAmount();

        uint256 rewardBalanceBefore = rewardToken.balanceOf(address(this));
        bool flaggedInCall;
        if (engine.flaggedAt(marketId, trader) == 0) {
            _engineCall(abi.encodeCall(IFxLiquidationEngine.flagAccount, (marketId, trader)));
            flaggedInCall = true;
        }

        bytes memory result =
            _engineCall(abi.encodeCall(IFxLiquidationEngine.liquidate, (marketId, trader, maxSizeToCloseAbsE18)));
        (liquidatorReward, socializedLoss) = abi.decode(result, (uint256, int256));

        uint256 rewardBalanceAfter = rewardToken.balanceOf(address(this));
        rewardForwarded = rewardBalanceAfter - rewardBalanceBefore;
        if (rewardForwarded != 0) {
            rewardToken.safeTransfer(rewardRecipient, rewardForwarded);
        }

        emit AtomicLiquidation(
            marketId,
            trader,
            msg.sender,
            rewardRecipient,
            flaggedInCall,
            liquidatorReward,
            socializedLoss,
            rewardForwarded
        );
    }

    function _engineCall(bytes memory callData) internal virtual returns (bytes memory result) {
        return proxyCalldata(address(engine), callData, false);
    }
}
