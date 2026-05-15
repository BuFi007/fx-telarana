// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IBufiKycPass} from "../interfaces/IBufiKycPass.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title FxGhostKycHook
/// @notice Minimal KYC/pass gate for future Ghost Mode v4 pools.
///
/// Data flow:
///   trusted Ghost router
///       |
///       v
///   PoolManager ---- beforeAddLiquidity / beforeSwap ----> this hook
///       |                                                    |
///       | hookData: abi.encode(GhostHookData)                |
///       |                                                    v
///       +---------------------------------------------> IBufiKycPass
///
/// This v1 hook only gates access. It does not return custom swap deltas and it
/// does not consume nullifiers directly. Commitment/nullifier accounting stays
/// in Ghost routers/registries until production verifier semantics are audited.
contract FxGhostKycHook is IHooks {
    uint256 private constant GHOST_HOOK_DATA_LENGTH = 96;

    struct GhostHookData {
        address account;
        bytes32 commitment;
        bytes32 nullifierHash;
    }

    IPoolManager public immutable POOL_MANAGER;
    IBufiKycPass public passVerifier;
    address public owner;
    uint8 public minPassLevel;

    mapping(address router => bool trusted) public trustedRouter;

    error NotOwner();
    error NotPoolManager();
    error ZeroAddress();
    error InvalidMinPassLevel(uint8 minPassLevel);
    error UntrustedRouter(address router);
    error InvalidHookData();
    error InvalidPass(address account, uint8 level, uint8 minLevel);
    error HookNotEnabled(bytes4 hook);

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event GhostHookPassVerifierSet(address indexed verifier);
    event GhostHookMinPassLevelSet(uint8 oldLevel, uint8 newLevel);
    event GhostHookTrustedRouterSet(address indexed router, bool trusted);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    constructor(address poolManager_, address passVerifier_, address initialOwner) {
        if (poolManager_ == address(0) || passVerifier_ == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }
        POOL_MANAGER = IPoolManager(poolManager_);
        passVerifier = IBufiKycPass(passVerifier_);
        owner = initialOwner;
        minPassLevel = 1;
        emit OwnerTransferred(address(0), initialOwner);
        emit GhostHookPassVerifierSet(passVerifier_);
        emit GhostHookMinPassLevelSet(0, 1);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPassVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        passVerifier = IBufiKycPass(verifier);
        emit GhostHookPassVerifierSet(verifier);
    }

    function setMinPassLevel(uint8 newLevel) external onlyOwner {
        if (newLevel == 0) revert InvalidMinPassLevel(newLevel);
        emit GhostHookMinPassLevelSet(minPassLevel, newLevel);
        minPassLevel = newLevel;
    }

    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        trustedRouter[router] = trusted;
        emit GhostHookTrustedRouterSet(router, trusted);
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeInitialize.selector);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotEnabled(IHooks.afterInitialize.selector);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external view onlyPoolManager returns (bytes4) {
        _assertGhostAuthorized(sender, hookData);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterAddLiquidity.selector);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeRemoveLiquidity.selector);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterRemoveLiquidity.selector);
    }

    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata hookData)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _assertGhostAuthorized(sender, hookData);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotEnabled(IHooks.afterSwap.selector);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeDonate.selector);
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotEnabled(IHooks.afterDonate.selector);
    }

    function _assertGhostAuthorized(address router, bytes calldata hookData)
        internal
        view
        returns (GhostHookData memory context)
    {
        if (!trustedRouter[router]) revert UntrustedRouter(router);
        if (hookData.length != GHOST_HOOK_DATA_LENGTH) revert InvalidHookData();

        context = abi.decode(hookData, (GhostHookData));
        if (context.account == address(0)) revert ZeroAddress();

        uint8 level = passVerifier.passLevel(context.account);
        if (!passVerifier.hasValidPass(context.account) || level < minPassLevel) {
            revert InvalidPass(context.account, level, minPassLevel);
        }
    }
}
