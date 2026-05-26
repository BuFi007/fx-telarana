// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title FxHedgeHook
/// @notice Uniswap v4 observer hook for BUFX delta-neutral LP pools.
/// @dev The hook does not custody funds or return custom deltas. It tracks the
///      configured hedge-token side of each pool and emits rebalance events for
///      the Rust matcher, which executes the corresponding BUFX perp hedge.
contract FxHedgeHook is IHooks, AccessControl {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    bytes32 public constant POOL_CONFIGURATOR_ROLE = keccak256("POOL_CONFIGURATOR_ROLE");

    IPoolManager public immutable POOL_MANAGER;
    uint256 public immutable defaultRebalanceThresholdE18;

    struct PoolHedgeConfig {
        bytes32 marketId;
        address hedgeToken;
        uint8 hedgeTokenDecimals;
        bytes32 pythFeedId;
        uint256 rebalanceThresholdE18;
        bool enabled;
    }

    mapping(bytes32 poolId => PoolHedgeConfig config) public poolConfigs;
    mapping(bytes32 poolId => int256 exposureE18) public poolExposureE18;
    mapping(bytes32 poolId => int256 hedgeSizeE18) public poolHedgeSizeE18;

    error NotPoolManager(address caller);
    error ZeroAddress();
    error InvalidPoolKey(bytes32 poolId);
    error InvalidDecimals(uint8 decimals);
    error InvalidRebalanceThreshold();
    error HedgeTokenNotInPool(bytes32 poolId, address hedgeToken);
    error PoolNotConfigured(bytes32 poolId);
    error HookNotEnabled(bytes4 selector);

    event PoolConfigured(
        bytes32 indexed poolId,
        bytes32 indexed marketId,
        address indexed hedgeToken,
        uint8 hedgeTokenDecimals,
        bytes32 pythFeedId,
        uint256 rebalanceThresholdE18,
        bool enabled
    );
    event ExposureChanged(
        bytes32 indexed poolId,
        bytes32 indexed marketId,
        address indexed hedgeToken,
        int256 oldExposureE18,
        int256 newExposureE18,
        int256 exposureDeltaE18
    );
    event HedgeRebalanced(
        bytes32 indexed poolId,
        bytes32 indexed marketId,
        address indexed hedgeToken,
        int256 oldHedgeSizeE18,
        int256 newHedgeSizeE18,
        int256 exposureE18,
        bytes32 pythFeedId
    );

    constructor(IPoolManager poolManager_, address initialAdmin, uint256 defaultRebalanceThresholdE18_) {
        if (address(poolManager_) == address(0) || initialAdmin == address(0)) revert ZeroAddress();
        if (defaultRebalanceThresholdE18_ == 0) revert InvalidRebalanceThreshold();

        POOL_MANAGER = poolManager_;
        defaultRebalanceThresholdE18 = defaultRebalanceThresholdE18_;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(POOL_CONFIGURATOR_ROLE, initialAdmin);

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager(msg.sender);
        _;
    }

    /// @notice v4 hook permission bits. Mine deploy address with these flags.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Configure hedge metadata for a v4 pool that uses this hook.
    function configurePool(
        PoolKey calldata key,
        bytes32 marketId,
        address hedgeToken,
        uint8 hedgeTokenDecimals,
        bytes32 pythFeedId,
        uint256 rebalanceThresholdE18,
        bool enabled
    ) external onlyRole(POOL_CONFIGURATOR_ROLE) {
        bytes32 poolId = _poolId(key);
        if (address(key.hooks) != address(this)) revert InvalidPoolKey(poolId);
        if (hedgeToken == address(0)) revert ZeroAddress();
        if (hedgeToken != Currency.unwrap(key.currency0) && hedgeToken != Currency.unwrap(key.currency1)) {
            revert HedgeTokenNotInPool(poolId, hedgeToken);
        }
        if (hedgeTokenDecimals > 18) revert InvalidDecimals(hedgeTokenDecimals);

        uint256 threshold = rebalanceThresholdE18 == 0 ? defaultRebalanceThresholdE18 : rebalanceThresholdE18;
        if (threshold == 0) revert InvalidRebalanceThreshold();

        poolConfigs[poolId] = PoolHedgeConfig({
            marketId: marketId,
            hedgeToken: hedgeToken,
            hedgeTokenDecimals: hedgeTokenDecimals,
            pythFeedId: pythFeedId,
            rebalanceThresholdE18: threshold,
            enabled: enabled
        });

        emit PoolConfigured(poolId, marketId, hedgeToken, hedgeTokenDecimals, pythFeedId, threshold, enabled);
    }

    /// @notice Current pool delta after the off-chain hedge: exposure + hedge.
    function currentDelta(bytes32 poolId) external view returns (int256) {
        return poolExposureE18[poolId] + poolHedgeSizeE18[poolId];
    }

    function isDeltaNeutral(bytes32 poolId) external view returns (bool) {
        PoolHedgeConfig memory config = poolConfigs[poolId];
        if (!config.enabled) revert PoolNotConfigured(poolId);
        return _abs(poolExposureE18[poolId] + poolHedgeSizeE18[poolId]) < config.rebalanceThresholdE18;
    }

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled(IHooks.beforeInitialize.selector);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled(IHooks.afterInitialize.selector);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeAddLiquidity.selector);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        _applyExposureDelta(key, delta);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeRemoveLiquidity.selector);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        _applyExposureDelta(key, delta);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotEnabled(IHooks.beforeSwap.selector);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        _applyExposureDelta(key, delta);
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled(IHooks.beforeDonate.selector);
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled(IHooks.afterDonate.selector);
    }

    function _applyExposureDelta(PoolKey calldata key, BalanceDelta delta) internal {
        bytes32 poolId = _poolId(key);
        PoolHedgeConfig memory config = poolConfigs[poolId];
        if (!config.enabled) revert PoolNotConfigured(poolId);

        int256 rawCallerDelta = _hedgeTokenDeltaRaw(key, config.hedgeToken, delta);
        int256 exposureDeltaE18 = -_rawToE18Signed(rawCallerDelta, config.hedgeTokenDecimals);
        if (exposureDeltaE18 == 0) return;

        int256 oldExposure = poolExposureE18[poolId];
        int256 newExposure = oldExposure + exposureDeltaE18;
        poolExposureE18[poolId] = newExposure;

        emit ExposureChanged(poolId, config.marketId, config.hedgeToken, oldExposure, newExposure, exposureDeltaE18);

        int256 oldHedge = poolHedgeSizeE18[poolId];
        if (_abs(newExposure + oldHedge) >= config.rebalanceThresholdE18) {
            int256 newHedge = -newExposure;
            poolHedgeSizeE18[poolId] = newHedge;
            emit HedgeRebalanced(
                poolId,
                config.marketId,
                config.hedgeToken,
                oldHedge,
                newHedge,
                newExposure,
                config.pythFeedId
            );
        }
    }

    function _hedgeTokenDeltaRaw(PoolKey calldata key, address hedgeToken, BalanceDelta delta)
        internal
        pure
        returns (int256)
    {
        if (hedgeToken == Currency.unwrap(key.currency0)) return int256(delta.amount0());
        if (hedgeToken == Currency.unwrap(key.currency1)) return int256(delta.amount1());
        revert HedgeTokenNotInPool(_poolId(key), hedgeToken);
    }

    function _rawToE18Signed(int256 amount, uint8 decimals) internal pure returns (int256) {
        if (decimals == 18) return amount;
        return amount * int256(10 ** (18 - decimals));
    }

    function _poolId(PoolKey calldata key) internal pure returns (bytes32) {
        PoolKey memory keyMem = key;
        return PoolId.unwrap(keyMem.toId());
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }
}
