// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";
import {ITelaranaGatewayHubHook} from "../interfaces/ITelaranaGatewayHubHook.sol";

/// @title FxSpotExecutor
/// @notice Phase A v0 spot-FX executor for fx-Telaraña. Plugs into
///         `TelaranaGatewayHubHook` (TGH) as a `destinationHub` for spot-FX
///         routes. After TGH mints USDC against a Circle Gateway attestation
///         and forwards it here, an authorized executor calls
///         `executeSpotFx(context)`, which:
///
///           1. Validates the TGH receipt for the request id.
///           2. Reads the oracle mid for (USDC, tokenOut).
///           3. Applies a configurable spread.
///           4. Asserts `amountOut >= context.minAmountOut`.
///           5. Asserts this contract holds enough `tokenOut` reserve.
///           6. Transfers `tokenOut` to `context.recipient`.
///           7. Calls back into TGH to mark the request settled.
///
/// V0 scope:
///   * Owner-managed liquidity (no LP shares, no Morpho rehyp).
///   * Single oracle source via `FxOracle.getMid` (Pyth-only). Owner can
///     flip `requireVerifiedOracle = true` once the keeper wraps tx with
///     RedStone calldata to engage `getMidVerified`.
///   * Configurable spread bps, default 5 bps for stable FX pairs.
///   * Single-leg only: USDC → enabled tokenOut. Reverse leg + multi-pair
///     routing comes in Phase B.
///   * No reserve isolation between tokens — relies on TGH's per-routeId
///     destinationHub config to confine which (USDC, tokenOut) flows reach
///     this executor.
///
/// Trust assumptions:
///   * TGH already validated the Circle attestation + minted exact amount.
///   * `context.recipient` is honest (BUFX submitter set it from the trader
///     request; submitter is authorized on BUFX side).
///   * `FxOracle` mid is the right anchor (Pyth + optional RedStone gate).
contract FxSpotExecutor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Operations role: manage liquidity reserves, pause/unpause.
    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    /// @dev Executor role: invoke `executeSpotFx`. Typically the keeper EOA.
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Cap on the configurable spread bps. 500 bps = 5%. Anything
    /// higher should trigger a manual review of the swap economics.
    uint256 public constant MAX_SPREAD_BPS = 500;

    IERC20 public immutable USDC;
    IFxOracle public immutable ORACLE;
    ITelaranaGatewayHubHook public immutable TELARANA_HUB_HOOK;

    /// @notice Per-request executed flag. Belt-and-braces over TGH's own
    /// `markGatewayAtomicFxSwapSettled` state machine.
    mapping(bytes32 requestId => bool executed) public executed;

    /// @notice Default spread applied to any enabled tokenOut, in bps.
    uint256 public defaultSpreadBps;

    /// @notice Per-token spread override. 0 means "use defaultSpreadBps".
    mapping(address token => uint256 bps) public tokenSpreadOverrideBps;

    /// @notice Token allowlist. We only swap USDC → tokens we've explicitly enabled.
    mapping(address token => bool enabled) public tokenEnabled;

    /// @notice When true, use FxOracle.getMidVerified (Pyth + RedStone deviation
    /// gate). Requires the executor caller to wrap its tx with RedStone SDK calldata.
    bool public requireVerifiedOracle;

    event SpotFxExecuted(
        bytes32 indexed requestId,
        bytes32 indexed routeId,
        address indexed recipient,
        address tokenOut,
        uint256 usdcIn,
        uint256 tokenOutDelivered,
        uint256 midE18,
        uint256 appliedSpreadBps
    );
    event LiquidityAdded(address indexed token, uint256 amount, address indexed from);
    event LiquidityWithdrawn(address indexed token, uint256 amount, address indexed to);
    event SpreadConfigured(address indexed token, uint256 bps);
    event TokenAllowlistSet(address indexed token, bool enabled);
    event RequireVerifiedOracleSet(bool required);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownRequest(bytes32 requestId);
    error AlreadyExecuted(bytes32 requestId);
    error TokenNotEnabled(address token);
    error InsufficientReserves(address token, uint256 wanted, uint256 available);
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error InvalidAction(uint8 action);
    error InvalidTokenOut(address tokenOut);
    error InvalidSpread(uint256 bps);
    error RouteIdMismatch(bytes32 expected, bytes32 actual);
    error AmountMismatch(uint256 expected, uint256 actual);
    error UsdcAsTokenOut();

    constructor(
        address usdc_,
        address oracle_,
        address tghAddress,
        address initialAdmin,
        uint256 initialDefaultSpreadBps
    ) {
        if (usdc_ == address(0) || oracle_ == address(0) || tghAddress == address(0) || initialAdmin == address(0)) {
            revert ZeroAddress();
        }
        if (initialDefaultSpreadBps > MAX_SPREAD_BPS) revert InvalidSpread(initialDefaultSpreadBps);

        USDC = IERC20(usdc_);
        ORACLE = IFxOracle(oracle_);
        TELARANA_HUB_HOOK = ITelaranaGatewayHubHook(tghAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
        _grantRole(EXECUTOR_ROLE, initialAdmin);

        defaultSpreadBps = initialDefaultSpreadBps;
        emit SpreadConfigured(address(0), initialDefaultSpreadBps);
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTE
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap USDC (already delivered by TGH) to context.tokenOut and pay
    ///         the recipient. Settles the TGH receipt atomically.
    /// @dev    Caller must have EXECUTOR_ROLE. This contract must hold both
    ///         (a) USDC equal to context.amount (delivered by TGH), and
    ///         (b) tokenOut reserve >= computed amountOut.
    function executeSpotFx(ITelaranaGatewayHubHook.GatewayMintContext calldata context)
        external
        whenNotPaused
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
        returns (uint256 amountOut)
    {
        // Idempotency: TGH also enforces this via state machine, but reverting
        // here gives a clearer error and a single source of truth for indexers.
        if (executed[context.requestId]) revert AlreadyExecuted(context.requestId);

        if (uint8(context.action) != uint8(ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX)) {
            revert InvalidAction(uint8(context.action));
        }
        if (context.recipient == address(0) || context.tokenOut == address(0)) revert ZeroAddress();
        if (context.tokenOut == address(USDC)) revert UsdcAsTokenOut();
        if (context.amount == 0) revert ZeroAmount();
        if (!tokenEnabled[context.tokenOut]) revert TokenNotEnabled(context.tokenOut);

        // Cross-check the TGH receipt — protects against context spoofing.
        // TGH stores the canonical receipt by requestId and only EXECUTOR_ROLE
        // can write it via `receiveGatewayMint`; we just read.
        ITelaranaGatewayHubHook.GatewayReceipt memory receipt =
            TELARANA_HUB_HOOK.gatewayReceipt(context.requestId);
        if (receipt.routeId != context.routeId) {
            revert RouteIdMismatch(receipt.routeId, context.routeId);
        }
        if (receipt.amount != context.amount) {
            revert AmountMismatch(receipt.amount, context.amount);
        }
        if (receipt.tokenOut != context.tokenOut) {
            revert InvalidTokenOut(context.tokenOut);
        }

        // Read oracle mid: getMid(USDC, tokenOut) returns (tokenOut per 1 USDC) * 1e18.
        // amountOut tokenOut = amountIn USDC * mid / 1e18. Decimal-adjusted by oracle.
        uint256 midE18;
        if (requireVerifiedOracle) {
            (midE18, ) = ORACLE.getMidVerified(address(USDC), context.tokenOut);
        } else {
            (midE18, ) = ORACLE.getMid(address(USDC), context.tokenOut);
        }

        uint256 spreadBps = tokenSpreadOverrideBps[context.tokenOut];
        if (spreadBps == 0) spreadBps = defaultSpreadBps;

        // Mid-anchored quote, less spread.
        // Multiplication order: mid first, then spread, to avoid early truncation.
        uint256 gross = context.amount * midE18 / 1e18;
        amountOut = gross * (10_000 - spreadBps) / 10_000;

        if (amountOut < context.minAmountOut) {
            revert SlippageExceeded(amountOut, context.minAmountOut);
        }

        uint256 reserveAvailable = IERC20(context.tokenOut).balanceOf(address(this));
        if (reserveAvailable < amountOut) {
            revert InsufficientReserves(context.tokenOut, amountOut, reserveAvailable);
        }

        // Effects before interactions.
        executed[context.requestId] = true;

        // Pay the recipient.
        IERC20(context.tokenOut).safeTransfer(context.recipient, amountOut);

        // Tell TGH the spot route is settled. Will revert if TGH receipt is
        // not in MINTED state (e.g., already settled), which gives us extra
        // belt-and-braces against state machine confusion.
        TELARANA_HUB_HOOK.markGatewayAtomicFxSwapSettled(context.requestId, amountOut);

        emit SpotFxExecuted(
            context.requestId,
            context.routeId,
            context.recipient,
            context.tokenOut,
            context.amount,
            amountOut,
            midE18,
            spreadBps
        );
    }

    /*//////////////////////////////////////////////////////////////
                                LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner-only seed liquidity. v0 has no LP shares. Phase F replaces
    ///         this with MetaMorpho-backed vault deposits.
    function addLiquidity(address token, uint256 amount) external onlyRole(OPERATIONS_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityAdded(token, amount, msg.sender);
    }

    /// @notice Owner-only liquidity withdrawal. Used to drain stale reserves
    ///         or rotate the pool. Will not revert on insufficient balance —
    ///         the underlying ERC20 transfer will.
    function withdrawLiquidity(address token, uint256 amount, address to) external onlyRole(OPERATIONS_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(token, amount, to);
    }

    function reserveOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setTokenEnabled(address token, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(USDC)) revert UsdcAsTokenOut();
        tokenEnabled[token] = enabled;
        emit TokenAllowlistSet(token, enabled);
    }

    function setDefaultSpreadBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_SPREAD_BPS) revert InvalidSpread(bps);
        defaultSpreadBps = bps;
        emit SpreadConfigured(address(0), bps);
    }

    function setTokenSpreadBps(address token, uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (bps > MAX_SPREAD_BPS) revert InvalidSpread(bps);
        tokenSpreadOverrideBps[token] = bps;
        emit SpreadConfigured(token, bps);
    }

    function setRequireVerifiedOracle(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requireVerifiedOracle = required;
        emit RequireVerifiedOracleSet(required);
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }
}
