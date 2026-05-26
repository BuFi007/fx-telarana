// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title FxHedgeHook
/// @notice Uniswap v4 hook that auto-hedges LP exposure via BUFX perps CLOB.
///
/// Hookathon entry: when an LP adds liquidity to cirBTC/USDC or JPYC/USDC,
/// the hook emits a HedgeRebalanced event. The off-chain Rust matcher
/// watches these events and opens the corresponding SHORT perps position
/// on the BUFX CLOB. The LP earns swap fees while remaining delta-neutral.
contract FxHedgeHook {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    bytes32 public immutable hedgeMarketId;
    IERC20 public immutable marginToken;
    uint256 public immutable rebalanceThreshold;

    int256 public currentHedgeSizeE18;
    int256 public currentExposureE18;

    event HedgeRebalanced(int256 oldSize, int256 newSize, int256 exposure);
    event ExposureChanged(int256 oldExposure, int256 newExposure);

    constructor(
        IPoolManager _poolManager,
        bytes32 _hedgeMarketId,
        IERC20 _marginToken,
        uint256 _rebalanceThreshold
    ) {
        poolManager = _poolManager;
        hedgeMarketId = _hedgeMarketId;
        marginToken = _marginToken;
        rebalanceThreshold = _rebalanceThreshold;
    }

    /// @notice Called after liquidity is added. Updates exposure and rebalances hedge.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        _updateExposure(int256(delta.amount0()));
        return (this.afterAddLiquidity.selector, delta);
    }

    /// @notice Called before liquidity is removed. Signals hedge closure.
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    /// @notice Called after every swap. Rebalances hedge if exposure changed.
    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        _updateExposure(int256(delta.amount0()));
        return (this.afterSwap.selector, 0);
    }

    function _updateExposure(int256 volatileAmount) internal {
        int256 oldExposure = currentExposureE18;
        currentExposureE18 += volatileAmount;
        emit ExposureChanged(oldExposure, currentExposureE18);

        int256 change = currentExposureE18 - oldExposure;
        if (change < 0) change = -change;
        if (uint256(change) >= rebalanceThreshold) {
            int256 oldHedge = currentHedgeSizeE18;
            currentHedgeSizeE18 = -currentExposureE18;
            emit HedgeRebalanced(oldHedge, currentHedgeSizeE18, currentExposureE18);
        }
    }

    /// @notice Current delta (0 = perfectly hedged).
    function currentDelta() external view returns (int256) {
        return currentExposureE18 + currentHedgeSizeE18;
    }

    function isDeltaNeutral() external view returns (bool) {
        int256 d = currentExposureE18 + currentHedgeSizeE18;
        if (d < 0) d = -d;
        return uint256(d) < rebalanceThreshold;
    }

    // --- Unused IHooks stubs (required by interface) ---

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }
    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
