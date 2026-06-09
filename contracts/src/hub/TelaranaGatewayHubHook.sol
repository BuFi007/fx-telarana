// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {ICircleGatewayMinter} from "../interfaces/ICircleGateway.sol";
import {IHyperlaneRecipient} from "../interfaces/IHyperlane.sol";
import {ITelaranaGatewayHubHook} from "../interfaces/ITelaranaGatewayHubHook.sol";

/// @title TelaranaGatewayHubHook
/// @notice Destination-hub wrapper for Circle Gateway USDC mints. Doubles as
///         a Uniswap v4 `IHooks` implementation that pulls Gateway-routed
///         intra-hook USDC liquidity inside `beforeSwap` — the Real-Time FX
///         Swap Pool Using Gateway differentiator (PR-H8 / Wave L2).
///
/// Data flow (legacy executor path, unchanged):
///   1. Operator/user deposits USDC into Circle Gateway Wallet on source hub.
///   2. Source signer signs Circle Gateway BurnIntent offchain.
///   3. Circle Gateway API returns attestation payload + signature.
///   4. Executor calls receiveGatewayMint(attestation, signature, context).
///   5. This hook calls GatewayMinter.gatewayMint(...).
///   6. This hook verifies exact USDC balance delta and forwards USDC to the
///      configured destination hub/router.
///   7. Optional spot-FX request event is emitted for future execution layers.
///
/// Data flow (intra-hook v4 path, NEW in PR-H8):
///   1. Admin binds a `PoolId` to an existing `routeId` via
///      `setPoolGatewayRoute(poolId, routeId)`.
///   2. Taker initiates a Uniswap v4 swap on the bound pool with the Gateway
///      attestation + signature + GatewayMintContext encoded in `hookData`.
///   3. PoolManager invokes `beforeSwap`. The hook reads the bound route,
///      validates the attached context, and atomically:
///        a. Calls `GATEWAY_MINTER.gatewayMint(attestation, signature)` —
///           USDC is minted into this hook INSTANTLY (<500ms equivalent;
///           no CCTP attestation polling).
///        b. Settles the materialized USDC to the PoolManager via the
///           returned `BeforeSwapDelta`.
///        c. Records the GatewayReceipt + emits `GatewayRoutedSwap` so
///           indexers (Ponder) can stitch the swap to the underlying
///           Gateway transfer.
///   4. PoolManager finalises the swap with no further external calls — the
///      whole intra-hook FX leg lands in a single user tx.
contract TelaranaGatewayHubHook is
    ITelaranaGatewayHubHook,
    IHooks,
    IHyperlaneRecipient,
    EIP712,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint8 public constant GATEWAY_CONTEXT_PROOF_VERSION = 1;
    bytes32 public constant GATEWAY_MINT_CONTEXT_TYPEHASH = keccak256(
        "GatewayMintContext(bytes32 routeId,bytes32 requestId,uint8 action,address sourceDepositor,address sourceSigner,address recipient,address tokenOut,uint256 amount,uint256 minAmountOut,bytes32 spotRouteId,bytes32 metadataRef)"
    );

    IERC20 public immutable USDC;
    ICircleGatewayMinter public immutable GATEWAY_MINTER;
    IPoolManager public immutable POOL_MANAGER;
    address public gatewayContextMailbox;

    mapping(bytes32 routeId => GatewayHubRoute route) private _gatewayRoutes;
    mapping(bytes32 requestId => GatewayReceipt receipt) private _gatewayReceipts;
    mapping(bytes32 routeId => GatewayContextProofMode mode) public gatewayContextProofMode;
    mapping(uint32 origin => mapping(bytes32 sender => bool trusted)) public gatewayContextTrustedSender;
    mapping(bytes32 requestId => bytes32 contextHash) public provenGatewayMintContextHash;

    /// @notice Binds a Uniswap v4 PoolId to an existing Gateway routeId. Used
    ///         by the `beforeSwap` intra-hook liquidity path to decide whether
    ///         a swap should pull USDC from Circle Gateway atomically (vs.
    ///         wait for CCTP).
    mapping(PoolId poolId => bytes32 routeId) public poolGatewayRouteBinding;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRoute(bytes32 routeId);
    error RouteDisabled(bytes32 routeId);
    error RouteMinterMismatch(address expected, address actual);
    error RouteTokenMismatch(address expected, address actual);
    error UnauthorizedRouteCaller(bytes32 routeId, address caller);
    error DuplicateRequest(bytes32 requestId);
    error RequestNotMinted(bytes32 requestId);
    error InvalidMintAmount(uint256 expected, uint256 actual);
    error InvalidSpotRequest();
    error SameGatewayDomain(uint32 domain);
    error UnexpectedHookData();
    error NotMailbox(address caller);
    error UntrustedGatewayContextSender(uint32 origin, bytes32 sender);
    error InvalidGatewayContextProof();
    error GatewayContextProofMissing(bytes32 requestId);
    error GatewayContextProofMismatch(bytes32 requestId, bytes32 expected, bytes32 actual);
    error NotPoolManager(address caller);
    error PoolGatewayRouteUnset(PoolId poolId);
    error InvalidBeforeSwapHookData();
    error PoolCurrencyNotUSDC(address actual);
    error UnsupportedSwapDirection();
    error HookNotEnabled(bytes4 selector);

    /// @notice Emitted whenever a v4 swap is satisfied by Gateway-routed
    ///         intra-hook USDC liquidity. Indexed by `poolId` so Ponder can
    ///         stitch the route to the underlying GatewayReceipt.
    event GatewayRoutedSwap(
        PoolId indexed poolId,
        bytes32 indexed routeId,
        bytes32 indexed requestId,
        address sender,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Admin-only binding event for indexers + ops dashboards.
    event PoolGatewayRouteBound(PoolId indexed poolId, bytes32 indexed routeId);
    event PoolGatewayRouteCleared(PoolId indexed poolId, bytes32 indexed previousRouteId);

    constructor(address usdc_, address gatewayMinter_, address poolManager_, address initialAdmin)
        EIP712("TelaranaGatewayHubHook", "2")
    {
        if (
            usdc_ == address(0) || gatewayMinter_ == address(0) || poolManager_ == address(0)
                || initialAdmin == address(0)
        ) {
            revert ZeroAddress();
        }

        USDC = IERC20(usdc_);
        GATEWAY_MINTER = ICircleGatewayMinter(gatewayMinter_);
        POOL_MANAGER = IPoolManager(poolManager_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
        _grantRole(EXECUTOR_ROLE, initialAdmin);
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    function gatewayRoute(bytes32 routeId) external view returns (GatewayHubRoute memory route) {
        return _gatewayRoutes[routeId];
    }

    function gatewayRequestState(bytes32 requestId) external view returns (GatewayRequestState state) {
        return _gatewayReceipts[requestId].state;
    }

    function gatewayReceipt(bytes32 requestId) external view returns (GatewayReceipt memory receipt) {
        return _gatewayReceipts[requestId];
    }

    function setGatewayRoute(bytes32 routeId, GatewayHubRoute calldata route) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRoute(routeId, route);
        _gatewayRoutes[routeId] = route;

        emit GatewayHubRouteConfigured(
            routeId,
            route.sourceDomain,
            route.destinationDomain,
            route.sourceUsdc,
            route.destinationUsdc,
            route.sourceGatewayWallet,
            route.destinationGatewayMinter,
            route.signerMode,
            route.enabled,
            route.metadataRef
        );
    }

    function setGatewaySignerMode(bytes32 routeId, GatewaySignerMode signerMode, bool allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        GatewayHubRoute storage route = _gatewayRoutes[routeId];
        if (route.destinationGatewayMinter == address(0)) revert InvalidRoute(routeId);

        if (allowed) {
            route.signerMode = signerMode;
        } else if (route.signerMode == signerMode) {
            route.enabled = false;
        }

        emit GatewaySignerModeUpdated(routeId, signerMode, allowed);
    }

    function setGatewayContextProofMode(bytes32 routeId, GatewayContextProofMode mode)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        GatewayHubRoute storage route = _gatewayRoutes[routeId];
        if (route.destinationGatewayMinter == address(0)) revert InvalidRoute(routeId);
        gatewayContextProofMode[routeId] = mode;
        emit GatewayContextProofModeUpdated(routeId, mode);
    }

    function setGatewayContextMailbox(address mailbox) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gatewayContextMailbox = mailbox;
        emit GatewayContextMailboxSet(mailbox);
    }

    function setGatewayContextTrustedSender(uint32 origin, bytes32 sender, bool trusted)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (sender == bytes32(0)) revert ZeroAddress();
        gatewayContextTrustedSender[origin][sender] = trusted;
        emit GatewayContextTrustedSenderSet(origin, sender, trusted);
    }

    function handle(uint32 origin, bytes32 sender, bytes calldata messageBody) external payable whenNotPaused {
        if (msg.sender != gatewayContextMailbox) revert NotMailbox(msg.sender);
        if (!gatewayContextTrustedSender[origin][sender]) revert UntrustedGatewayContextSender(origin, sender);

        (uint8 version, bytes32 requestId, bytes32 routeId, bytes32 contextHash) =
            abi.decode(messageBody, (uint8, bytes32, bytes32, bytes32));
        if (version != GATEWAY_CONTEXT_PROOF_VERSION || requestId == bytes32(0) || contextHash == bytes32(0)) {
            revert InvalidGatewayContextProof();
        }

        provenGatewayMintContextHash[requestId] = contextHash;
        emit GatewayContextHashProven(requestId, routeId, origin, sender, contextHash);
    }

    function gatewayMintContextStructHash(GatewayMintContext calldata context) public pure returns (bytes32) {
        return _gatewayMintContextStructHash(context);
    }

    function gatewayMintContextDigest(GatewayMintContext calldata context) external view returns (bytes32) {
        return _hashTypedDataV4(_gatewayMintContextStructHash(context));
    }

    function receiveGatewayMint(
        bytes calldata attestationPayload,
        bytes calldata signature,
        GatewayMintContext calldata context
    ) external whenNotPaused nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256 amountReceived) {
        GatewayHubRoute memory route = _validatedRouteForMint(context);

        _gatewayReceipts[context.requestId].state = GatewayRequestState.MINTED;

        uint256 balanceBefore = USDC.balanceOf(address(this));
        GATEWAY_MINTER.gatewayMint(attestationPayload, signature);
        uint256 balanceAfter = USDC.balanceOf(address(this));

        amountReceived = balanceAfter - balanceBefore;
        if (amountReceived != context.amount) revert InvalidMintAmount(context.amount, amountReceived);

        _gatewayReceipts[context.requestId] = GatewayReceipt({
            routeId: context.routeId,
            state: GatewayRequestState.MINTED,
            action: context.action,
            sourceDepositor: context.sourceDepositor,
            sourceSigner: context.sourceSigner,
            recipient: context.recipient,
            tokenOut: context.tokenOut,
            amount: amountReceived,
            minAmountOut: context.minAmountOut,
            spotRouteId: context.spotRouteId,
            metadataRef: context.metadataRef
        });

        if (route.destinationHub != address(this)) {
            USDC.safeTransfer(route.destinationHub, amountReceived);
        }

        emit GatewayHubMintAttested(
            context.requestId, context.routeId, address(GATEWAY_MINTER), keccak256(attestationPayload)
        );
        emit GatewayHubLiquidityReceived(
            context.requestId, context.routeId, context.recipient, address(USDC), amountReceived
        );

        if (context.action == GatewayHubAction.MINT_AND_REQUEST_SPOT_FX) {
            emit GatewayAtomicFxSwapRequested(
                context.requestId,
                context.routeId,
                context.spotRouteId,
                context.tokenOut,
                amountReceived,
                context.minAmountOut,
                context.recipient,
                context.metadataRef
            );
        }
    }

    function markGatewayAtomicFxSwapSettled(bytes32 requestId, uint256 amountOut) external onlyRole(EXECUTOR_ROLE) {
        GatewayReceipt storage receipt = _gatewayReceipts[requestId];
        if (receipt.state != GatewayRequestState.MINTED) revert RequestNotMinted(requestId);
        if (receipt.action != GatewayHubAction.MINT_AND_REQUEST_SPOT_FX) revert InvalidSpotRequest();

        receipt.state = GatewayRequestState.SETTLED;

        emit GatewayAtomicFxSwapSettled(requestId, receipt.spotRouteId, receipt.recipient, receipt.tokenOut, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                        UNISWAP V4 — IHooks SURFACE
                  Gateway-routed intra-hook liquidity (PR-H8)
    //////////////////////////////////////////////////////////////*/

    /// @notice Binds a Uniswap v4 PoolId to an existing Gateway routeId.
    ///         While the binding is set, `beforeSwap` will atomically pull
    ///         USDC liquidity from Circle Gateway on this chain for any swap
    ///         routed through that pool.
    /// @dev    The bound `routeId` must already be configured via
    ///         `setGatewayRoute(...)`. Admin-gated; bindings are read-only
    ///         from the swap surface.
    function setPoolGatewayRoute(PoolId poolId, bytes32 routeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (PoolId.unwrap(poolId) == bytes32(0)) revert InvalidRoute(routeId);
        if (routeId == bytes32(0)) revert InvalidRoute(routeId);
        if (_gatewayRoutes[routeId].destinationGatewayMinter == address(0)) revert InvalidRoute(routeId);
        poolGatewayRouteBinding[poolId] = routeId;
        emit PoolGatewayRouteBound(poolId, routeId);
    }

    /// @notice Clear a Pool ↔ route binding. Future swaps on the pool will
    ///         revert at the IHooks surface (no implicit CCTP fallback —
    ///         that's the differentiator of this hook over CCTP-only flows).
    function clearPoolGatewayRoute(PoolId poolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 previous = poolGatewayRouteBinding[poolId];
        if (previous == bytes32(0)) revert PoolGatewayRouteUnset(poolId);
        delete poolGatewayRouteBinding[poolId];
        emit PoolGatewayRouteCleared(poolId, previous);
    }

    /// @notice v4 hook permission bits. Address bits MUST match.
    /// @dev    BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA enabled — the hook
    ///         intercepts every swap and returns a delta that absorbs the
    ///         user's input + credits Gateway-minted USDC out. All other
    ///         lifecycle callbacks are disabled.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Only the PoolManager is allowed to invoke any IHooks callback.
    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager(msg.sender);
        _;
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeInitialize.selector);
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotEnabled(IHooks.afterInitialize.selector);
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeAddLiquidity.selector);
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterAddLiquidity.selector);
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotEnabled(IHooks.beforeRemoveLiquidity.selector);
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotEnabled(IHooks.afterRemoveLiquidity.selector);
    }

    /// @inheritdoc IHooks
    /// @notice The load-bearing differentiator of PR-H8. Pulls USDC from
    ///         Circle Gateway INSTANTLY (no CCTP attestation polling) and
    ///         returns a `BeforeSwapDelta` that PoolManager uses to settle
    ///         the swap in a single transaction.
    /// @dev    Security:
    ///           - `msg.sender == POOL_MANAGER` enforced.
    ///           - Hook must be unpaused.
    ///           - Pool must have a bound Gateway route.
    ///           - `hookData` must encode (attestation, signature, context).
    ///           - The context's `requestId` is checked for replay via the
    ///             shared `_gatewayReceipts` mapping.
    ///           - USDC balance delta is measured directly — never trust the
    ///             attestation's `value` field.
    /// @dev    Delta convention: caller specifies exact-input swap of currency
    ///         X for USDC. We absorb the entire `params.amountSpecified` on
    ///         the specified currency (input) and credit the Gateway-minted
    ///         USDC on the unspecified side. The pool currency that maps to
    ///         USDC determines which side of the BeforeSwapDelta is positive.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager whenNotPaused nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        bytes32 routeId = poolGatewayRouteBinding[poolId];
        if (routeId == bytes32(0)) revert PoolGatewayRouteUnset(poolId);

        if (hookData.length == 0) revert InvalidBeforeSwapHookData();

        // Locate which pool currency is USDC. We only support pools where
        // exactly one side is the canonical USDC backing this hub hook.
        bool usdcIsCurrency0;
        if (Currency.unwrap(key.currency0) == address(USDC)) {
            usdcIsCurrency0 = true;
        } else if (Currency.unwrap(key.currency1) == address(USDC)) {
            usdcIsCurrency0 = false;
        } else {
            revert PoolCurrencyNotUSDC(address(USDC));
        }

        // The "Gateway-routed" leg always materialises USDC OUT to the user.
        // params.zeroForOne == true means user pays currency0 and receives
        // currency1. So USDC must be on the receiving side.
        bool userReceivesUsdc = params.zeroForOne ? !usdcIsCurrency0 : usdcIsCurrency0;
        if (!userReceivesUsdc) revert UnsupportedSwapDirection();

        // F-1: exact-input only. The hook takes the caller's specified input and
        // credits the Gateway-minted USDC out. An exact-output swap would let the
        // caller name an output while paying an unrelated (e.g. ~0) input.
        if (params.amountSpecified > 0) revert UnsupportedSwapDirection();

        // Decode hookData payload and run the canonical attestation flow.
        (bytes memory attestationPayload, bytes memory signature, GatewayMintContext memory context) =
            abi.decode(hookData, (bytes, bytes, GatewayMintContext));

        if (context.routeId != routeId) revert InvalidRoute(routeId);
        if (_gatewayReceipts[context.requestId].state != GatewayRequestState.UNKNOWN) {
            revert DuplicateRequest(context.requestId);
        }
        if (context.amount == 0) revert ZeroAmount();
        if (context.recipient == address(0) || context.sourceDepositor == address(0) || context.sourceSigner == address(0))
        {
            revert ZeroAddress();
        }

        // Validate the route against current hook state. We re-read storage
        // (rather than trusting a `_validatedRouteForMint`-style memory copy)
        // because the v4 hook path allows public callers — the function is
        // ungated apart from PoolManager forwarding the call. Defence in depth.
        GatewayHubRoute memory route = _gatewayRoutes[routeId];
        if (!route.enabled) revert RouteDisabled(routeId);
        if (route.destinationGatewayMinter != address(GATEWAY_MINTER)) {
            revert RouteMinterMismatch(address(GATEWAY_MINTER), route.destinationGatewayMinter);
        }
        if (route.destinationUsdc != address(USDC)) {
            revert RouteTokenMismatch(address(USDC), route.destinationUsdc);
        }

        // F-38/F-1: the v4 mint path MUST enforce the same trust boundary as
        // `receiveGatewayMint`. Without this, any observer holding a valid Circle
        // attestation for this route could mint protocol-locked USDC into the
        // pool. A bound pool therefore REQUIRES a non-zero whitelisted caller
        // (stricter than the executor path, where 0 means "EXECUTOR_ROLE only"),
        // and `sender` (the v4 swap initiator) must match it. The context proof
        // mode configured for the route is honored exactly as in the mint path.
        if (route.whitelistedCaller == address(0) || sender != route.whitelistedCaller) {
            revert UnauthorizedRouteCaller(routeId, sender);
        }
        _verifyGatewayContextProofMemory(context);

        // Pre-record the receipt to prevent reentrant duplicate-request races
        // against the GatewayMinter.
        _gatewayReceipts[context.requestId].state = GatewayRequestState.MINTED;

        // Atomic mint. Balance-delta is the source of truth — never the
        // attestation's value field. Mirrors `receiveGatewayMint`.
        uint256 balanceBefore = USDC.balanceOf(address(this));
        GATEWAY_MINTER.gatewayMint(attestationPayload, signature);
        uint256 balanceAfter = USDC.balanceOf(address(this));
        uint256 amountReceived = balanceAfter - balanceBefore;
        if (amountReceived != context.amount) revert InvalidMintAmount(context.amount, amountReceived);

        // Persist full receipt (post-mint).
        _gatewayReceipts[context.requestId] = GatewayReceipt({
            routeId: context.routeId,
            state: GatewayRequestState.SETTLED, // v4 path → swap is atomic, settled here
            action: context.action,
            sourceDepositor: context.sourceDepositor,
            sourceSigner: context.sourceSigner,
            recipient: context.recipient,
            tokenOut: context.tokenOut,
            amount: amountReceived,
            minAmountOut: context.minAmountOut,
            spotRouteId: context.spotRouteId,
            metadataRef: context.metadataRef
        });

        emit GatewayHubMintAttested(context.requestId, routeId, address(GATEWAY_MINTER), keccak256(attestationPayload));
        emit GatewayHubLiquidityReceived(context.requestId, routeId, context.recipient, address(USDC), amountReceived);

        // Settle the USDC output side to the PoolManager.
        // BeforeSwapDelta convention:
        //   - upper 128 bits = specifiedDelta (the side the user specified)
        //   - lower 128 bits = unspecifiedDelta (the other side)
        // For exact-input swap (amountSpecified < 0): user pays |amount| on the
        // specified side. We don't take that input here (the pool will route
        // it via standard swap settlement; we only inject Gateway liquidity).
        // We owe `amountReceived` USDC to PoolManager → settle.
        // The unspecified delta we return must net out to the credit we just
        // generated by depositing USDC into PoolManager.
        // F-1: collect the caller's input on the specified side. Against the
        // empty pool, NOT taking the input is the free-drain bug — the swapper
        // would receive the full Gateway-minted USDC for ~0 input. We take the
        // exact specified input into the hook and report it as a positive
        // specified delta (mirrors FxSwapHook.beforeSwap).
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        uint256 amountIn = uint256(-params.amountSpecified);
        inputCurrency.take(POOL_MANAGER, address(this), amountIn, false);

        // Credit the Gateway-minted USDC to the PoolManager (unspecified/output).
        Currency outputCurrency = usdcIsCurrency0 ? key.currency0 : key.currency1;
        POOL_MANAGER.sync(outputCurrency);
        USDC.safeTransfer(address(POOL_MANAGER), amountReceived);
        POOL_MANAGER.settle();

        // BeforeSwapDelta convention (mirrors FxSwapHook):
        //   - specified delta = +amountIn  → the hook absorbed the caller's input
        //   - unspecified delta = -amountReceived → the hook supplied USDC out
        BeforeSwapDelta delta = toBeforeSwapDelta(_toInt128(amountIn), -_toInt128(amountReceived));

        emit GatewayRoutedSwap(poolId, routeId, context.requestId, sender, amountIn, amountReceived);

        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        revert HookNotEnabled(IHooks.afterSwap.selector);
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled(IHooks.beforeDonate.selector);
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotEnabled(IHooks.afterDonate.selector);
    }

    function _toInt128(uint256 value) internal pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert ZeroAmount();
        return int128(int256(value));
    }

    function _validatedRouteForMint(GatewayMintContext calldata context)
        internal
        view
        returns (GatewayHubRoute memory route)
    {
        if (context.requestId == bytes32(0) || context.routeId == bytes32(0)) revert InvalidRoute(context.routeId);
        if (_gatewayReceipts[context.requestId].state != GatewayRequestState.UNKNOWN) {
            revert DuplicateRequest(context.requestId);
        }
        if (context.amount == 0) revert ZeroAmount();
        if (
            context.sourceDepositor == address(0) || context.sourceSigner == address(0)
                || context.recipient == address(0)
        ) {
            revert ZeroAddress();
        }

        route = _gatewayRoutes[context.routeId];
        if (route.destinationGatewayMinter == address(0)) revert InvalidRoute(context.routeId);
        if (!route.enabled) revert RouteDisabled(context.routeId);
        if (route.destinationGatewayMinter != address(GATEWAY_MINTER)) {
            revert RouteMinterMismatch(address(GATEWAY_MINTER), route.destinationGatewayMinter);
        }
        if (route.destinationUsdc != address(USDC)) {
            revert RouteTokenMismatch(address(USDC), route.destinationUsdc);
        }
        if (
            route.destinationHub == address(0) || route.sourceUsdc == address(0)
                || route.sourceGatewayWallet == address(0)
        ) {
            revert ZeroAddress();
        }
        if (route.whitelistedCaller != address(0) && msg.sender != route.whitelistedCaller) {
            revert UnauthorizedRouteCaller(context.routeId, msg.sender);
        }

        if (uint8(context.action) > uint8(GatewayHubAction.MINT_AND_REQUEST_SPOT_FX)) {
            revert InvalidSpotRequest();
        } else if (context.action == GatewayHubAction.MINT_TO_HUB) {
            if (context.tokenOut != address(0) || context.spotRouteId != bytes32(0) || context.minAmountOut != 0) {
                revert InvalidSpotRequest();
            }
        } else if (context.action == GatewayHubAction.MINT_AND_REQUEST_SPOT_FX) {
            if (context.tokenOut == address(0) || context.spotRouteId == bytes32(0) || context.minAmountOut == 0) {
                revert InvalidSpotRequest();
            }
        }

        _verifyGatewayContextProof(context);
    }

    function _validateRoute(bytes32 routeId, GatewayHubRoute calldata route) internal view {
        if (routeId == bytes32(0)) revert InvalidRoute(routeId);
        if (route.sourceDomain == route.destinationDomain) revert SameGatewayDomain(route.sourceDomain);
        if (
            route.sourceUsdc == address(0) || route.destinationUsdc == address(0)
                || route.sourceGatewayWallet == address(0) || route.destinationGatewayMinter == address(0)
                || route.destinationHub == address(0)
        ) {
            revert ZeroAddress();
        }
        if (route.destinationGatewayMinter != address(GATEWAY_MINTER)) {
            revert RouteMinterMismatch(address(GATEWAY_MINTER), route.destinationGatewayMinter);
        }
        if (route.destinationUsdc != address(USDC)) {
            revert RouteTokenMismatch(address(USDC), route.destinationUsdc);
        }
    }

    function _verifyGatewayContextProof(GatewayMintContext calldata context) internal view {
        GatewayContextProofMode mode = gatewayContextProofMode[context.routeId];
        if (mode == GatewayContextProofMode.NONE) {
            if (context.hookData.length != 0) revert UnexpectedHookData();
            return;
        }

        bytes32 structHash = _gatewayMintContextStructHash(context);
        bytes32 provenHash = provenGatewayMintContextHash[context.requestId];
        bool hyperlaneProven = provenHash == structHash;

        if (mode == GatewayContextProofMode.SIGNED_INTENT) {
            if (!_hasValidSignedIntent(context, structHash)) revert GatewayContextProofMissing(context.requestId);
        } else if (mode == GatewayContextProofMode.HYPERLANE) {
            if (context.hookData.length != 0) revert UnexpectedHookData();
            if (!hyperlaneProven) {
                revert GatewayContextProofMismatch(context.requestId, structHash, provenHash);
            }
        } else if (mode == GatewayContextProofMode.SIGNED_INTENT_OR_HYPERLANE) {
            if (hyperlaneProven) return;
            if (_hasValidSignedIntent(context, structHash)) return;
            if (provenHash != bytes32(0)) {
                revert GatewayContextProofMismatch(context.requestId, structHash, provenHash);
            }
            revert GatewayContextProofMissing(context.requestId);
        } else {
            revert InvalidGatewayContextProof();
        }
    }

    function _hasValidSignedIntent(GatewayMintContext calldata context, bytes32 structHash)
        internal
        view
        returns (bool)
    {
        if (context.hookData.length == 0) return false;
        GatewayContextProof memory proof = abi.decode(context.hookData, (GatewayContextProof));
        if (proof.version != GATEWAY_CONTEXT_PROOF_VERSION || proof.sourceDepositorSignature.length == 0) {
            revert InvalidGatewayContextProof();
        }
        bytes32 digest = _hashTypedDataV4(structHash);
        return SignatureChecker.isValidSignatureNow(context.sourceDepositor, digest, proof.sourceDepositorSignature);
    }

    function _gatewayMintContextStructHash(GatewayMintContext calldata context) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                GATEWAY_MINT_CONTEXT_TYPEHASH,
                context.routeId,
                context.requestId,
                uint8(context.action),
                context.sourceDepositor,
                context.sourceSigner,
                context.recipient,
                context.tokenOut,
                context.amount,
                context.minAmountOut,
                context.spotRouteId,
                context.metadataRef
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
        MEMORY-CONTEXT PROOF HELPERS (v4 beforeSwap path — F-38)
        Mirror the calldata variants exactly; the swap path decodes the
        GatewayMintContext from `hookData` into memory, so it cannot reuse the
        calldata-typed helpers used by `receiveGatewayMint`.
    //////////////////////////////////////////////////////////////*/

    function _verifyGatewayContextProofMemory(GatewayMintContext memory context) internal view {
        GatewayContextProofMode mode = gatewayContextProofMode[context.routeId];
        if (mode == GatewayContextProofMode.NONE) {
            if (context.hookData.length != 0) revert UnexpectedHookData();
            return;
        }

        bytes32 structHash = _gatewayMintContextStructHashMemory(context);
        bytes32 provenHash = provenGatewayMintContextHash[context.requestId];
        bool hyperlaneProven = provenHash == structHash;

        if (mode == GatewayContextProofMode.SIGNED_INTENT) {
            if (!_hasValidSignedIntentMemory(context, structHash)) revert GatewayContextProofMissing(context.requestId);
        } else if (mode == GatewayContextProofMode.HYPERLANE) {
            if (context.hookData.length != 0) revert UnexpectedHookData();
            if (!hyperlaneProven) {
                revert GatewayContextProofMismatch(context.requestId, structHash, provenHash);
            }
        } else if (mode == GatewayContextProofMode.SIGNED_INTENT_OR_HYPERLANE) {
            if (hyperlaneProven) return;
            if (_hasValidSignedIntentMemory(context, structHash)) return;
            if (provenHash != bytes32(0)) {
                revert GatewayContextProofMismatch(context.requestId, structHash, provenHash);
            }
            revert GatewayContextProofMissing(context.requestId);
        } else {
            revert InvalidGatewayContextProof();
        }
    }

    function _hasValidSignedIntentMemory(GatewayMintContext memory context, bytes32 structHash)
        internal
        view
        returns (bool)
    {
        if (context.hookData.length == 0) return false;
        GatewayContextProof memory proof = abi.decode(context.hookData, (GatewayContextProof));
        if (proof.version != GATEWAY_CONTEXT_PROOF_VERSION || proof.sourceDepositorSignature.length == 0) {
            revert InvalidGatewayContextProof();
        }
        bytes32 digest = _hashTypedDataV4(structHash);
        return SignatureChecker.isValidSignatureNow(context.sourceDepositor, digest, proof.sourceDepositorSignature);
    }

    function _gatewayMintContextStructHashMemory(GatewayMintContext memory context) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                GATEWAY_MINT_CONTEXT_TYPEHASH,
                context.routeId,
                context.requestId,
                uint8(context.action),
                context.sourceDepositor,
                context.sourceSigner,
                context.recipient,
                context.tokenOut,
                context.amount,
                context.minAmountOut,
                context.spotRouteId,
                context.metadataRef
            )
        );
    }
}
