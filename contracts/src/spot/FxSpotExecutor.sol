// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";
import {ITelaranaGatewayHubHook} from "../interfaces/ITelaranaGatewayHubHook.sol";

/// @title FxSpotExecutor
/// @notice Phase A v0.2 spot-FX executor for fx-Telaraña. Plugs into
///         `TelaranaGatewayHubHook` (TGH) as a `destinationHub` for spot-FX
///         routes. After TGH mints USDC against a Circle Gateway attestation
///         and forwards it here, an authorized executor calls
///         `executeSpotFx(requestId)`, which:
///
///           1. Reads the canonical TGH receipt by `requestId` and rejects
///              if state != MINTED or action != MINT_AND_REQUEST_SPOT_FX.
///           2. Reads the oracle mid for (USDC, receipt.tokenOut).
///           3. Applies a configurable spread.
///           4. Asserts `amountOut >= receipt.minAmountOut`.
///           5. Asserts this contract holds enough `tokenOut` reserve.
///           6. Transfers `tokenOut` to `receipt.recipient`.
///           7. Calls back into TGH to mark the request settled.
///
/// ## v0.1 changelog vs v0
///
/// v0 took a `GatewayMintContext` calldata argument that the keeper provided
/// and only cross-checked `routeId / amount / tokenOut` against the TGH
/// receipt. Codex's adversarial pass (2026-05-16, see
/// `reports/AUDIT_REPORT.md`) raised this to CRITICAL: a compromised keeper
/// could spoof `recipient` and `minAmountOut` to drain reserves to an
/// attacker address. v0.1 collapses the surface — the keeper supplies only
/// the `requestId`; every other value comes from the TGH receipt, which is
/// the single source of truth.
///
/// ## v0.2 changelog vs v0.1
///
/// v0.1 refused to allowlist tokens whose decimals differed from USDC because
/// its payout math assumed identical atomic-unit decimals. v0.2 stores
/// `IERC20Metadata.decimals(tokenOut)` at allowlist time and scales the quote
/// through 18-decimal oracle precision before scaling to tokenOut decimals.
/// The decimal normalization mirrors Synthetix v3's `Price.scale/scaleTo`
/// pattern in
/// `contracts/lib/synthetix-v3/markets/spot-market/contracts/storage/Price.sol`.
///
/// ## V0.2 scope (intentional)
///
///   * Owner-managed liquidity (no LP shares, no Morpho rehyp).
///   * Single oracle source via `FxOracle.getMid` (Pyth-only). Owner can
///     flip `requireVerifiedOracle = true` once the keeper wraps tx with
///     RedStone calldata to engage `getMidVerified`.
///   * Configurable spread bps, default 5 bps for stable FX pairs.
///   * Single-leg only: USDC → enabled tokenOut, decimal-aware up to
///     `MAX_TOKEN_DECIMALS`.
///
/// ## Pricing formula reference
///
/// The pricing math is the standard oracle-anchored synth-exchange shape:
///
///   `amountOut = scaleTo(scale(amountIn, usdcDecimals) * mid / 1e18, tokenOutDecimals) * (1 - spread)`
///
/// implemented with OZ `Math.mulDiv` for decimal scaling, oracle price, and
/// spread arithmetic. Same arithmetic shape used by vendored references:
///   * `contracts/lib/gmx-synthetics/contracts/swap/SwapUtils.sol`, which
///     computes `amountOut = amountIn * tokenInPrice / tokenOutPrice` after
///     fees and impact adjustments.
///   * `contracts/lib/gmx-synthetics/contracts/pricing/SwapPricingUtils.sol`,
///     which applies swap fee factors before output calculation.
///   * `contracts/lib/synthetix-v3/markets/spot-market/contracts/storage/Price.sol`,
///     which provides the decimal scaling pattern used for the v0.2 follow-up.
///
/// No bonding curve, no integrals, no in-house derivations. Per the
/// project's "no novel math in production" rule.
///
/// ## Future v4-hook wrap (Phase A v1)
///
/// This contract is the pre-hook surface. When Uniswap v4 PoolManager
/// ships on Arc, this surface gets wrapped by an inheriting v4 hook
/// modeled on OZ's `BaseCustomCurve`
/// (`contracts/lib/openzeppelin-uniswap-hooks/src/base/BaseCustomCurve.sol`).
/// At that point `_getUnspecifiedAmount` will compute the same
/// oracle-anchored quote this contract computes today, and the hook bits
/// will gate access. Until then, this executor stays keeper-driven via
/// `EXECUTOR_ROLE`.
///
/// ## Trust assumptions
///
///   * TGH already validated the Circle attestation + minted exact amount.
///   * TGH's recorded receipt is canonical. (Compromised keeper at
///     TGH.receiveGatewayMint time is upstream of this contract and is a
///     Telarana-side risk.)
///   * `FxOracle` mid is the right anchor (Pyth + optional RedStone gate).
contract FxSpotExecutor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev Operations role: manage liquidity reserves, pause/unpause.
    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");
    /// @dev Executor role: invoke `executeSpotFx`. Typically the keeper EOA.
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Cap on the configurable spread bps. 500 bps = 5%. Anything
    /// higher should trigger a manual review of the swap economics.
    uint256 public constant MAX_SPREAD_BPS = 500;
    /// @notice Cap token decimals to keep decimal scaling within practical ERC20 ranges.
    uint8 public constant MAX_TOKEN_DECIMALS = 36;
    /// @notice Oracle prices are 18-decimal fixed point.
    uint8 public constant ORACLE_DECIMALS = 18;

    IERC20 public immutable USDC;
    uint8 public immutable USDC_DECIMALS;
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
    /// @notice TokenOut decimals captured at allowlist time.
    mapping(address token => uint8 decimals) public tokenDecimals;

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
    event TokenDecimalsStored(address indexed token, uint8 decimals);
    event RequireVerifiedOracleSet(bool required);

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyExecuted(bytes32 requestId);
    error TokenNotEnabled(address token);
    error InsufficientReserves(address token, uint256 wanted, uint256 available);
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error InvalidAction(uint8 action);
    error InvalidSpread(uint256 bps);
    error UsdcAsTokenOut();
    error ReceiptNotMinted(bytes32 requestId, uint8 actualState);
    error TokenDecimalsTooLarge(address token, uint8 decimals);
    error EmptyReceipt(bytes32 requestId);

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
        USDC_DECIMALS = IERC20Metadata(usdc_).decimals();
        if (USDC_DECIMALS > MAX_TOKEN_DECIMALS) revert TokenDecimalsTooLarge(usdc_, USDC_DECIMALS);
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

    /// @notice Settle a spot-FX swap from USDC (already delivered by TGH) to
    ///         the tokenOut named in the TGH receipt and pay the receipt's
    ///         recipient. Settles the TGH receipt atomically.
    /// @dev    Caller must have EXECUTOR_ROLE. This contract must hold both
    ///         (a) USDC equal to receipt.amount (delivered by TGH), and
    ///         (b) tokenOut reserve >= computed amountOut.
    /// @param requestId The TGH receipt id. The keeper does not supply
    ///        recipient / minAmountOut / amount / tokenOut — all read from
    ///        the canonical receipt. This is the v0.1 fix for Codex CRITICAL.
    function executeSpotFx(bytes32 requestId)
        external
        whenNotPaused
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
        returns (uint256 amountOut)
    {
        // Idempotency: TGH also enforces this via state machine, but reverting
        // here gives a clearer error and a single source of truth for indexers.
        if (executed[requestId]) revert AlreadyExecuted(requestId);

        // Read the canonical receipt from TGH. All swap parameters come from
        // here — the keeper supplies only `requestId`.
        ITelaranaGatewayHubHook.GatewayReceipt memory receipt = TELARANA_HUB_HOOK.gatewayReceipt(requestId);

        if (receipt.amount == 0) revert EmptyReceipt(requestId);
        if (receipt.state != ITelaranaGatewayHubHook.GatewayRequestState.MINTED) {
            revert ReceiptNotMinted(requestId, uint8(receipt.state));
        }
        if (uint8(receipt.action) != uint8(ITelaranaGatewayHubHook.GatewayHubAction.MINT_AND_REQUEST_SPOT_FX)) {
            revert InvalidAction(uint8(receipt.action));
        }
        if (receipt.recipient == address(0) || receipt.tokenOut == address(0)) revert ZeroAddress();
        if (receipt.tokenOut == address(USDC)) revert UsdcAsTokenOut();
        if (!tokenEnabled[receipt.tokenOut]) revert TokenNotEnabled(receipt.tokenOut);

        uint8 outDecimals = tokenDecimals[receipt.tokenOut];

        // Read oracle mid: getMid(USDC, tokenOut) returns (tokenOut per 1 USDC) * 1e18.
        uint256 midE18;
        if (requireVerifiedOracle) {
            (midE18,) = ORACLE.getMidVerified(address(USDC), receipt.tokenOut);
        } else {
            (midE18,) = ORACLE.getMid(address(USDC), receipt.tokenOut);
        }

        uint256 spreadBps = tokenSpreadOverrideBps[receipt.tokenOut];
        if (spreadBps == 0) spreadBps = defaultSpreadBps;

        // Two-step `mulDiv` (OZ Math). See contract NatSpec "Pricing formula
        // reference" for vendored GMX/Synthetix reference paths.
        uint256 amountInE18 = _scaleDecimals(receipt.amount, USDC_DECIMALS, ORACLE_DECIMALS);
        uint256 grossE18 = amountInE18.mulDiv(midE18, 1e18);
        uint256 gross = _scaleDecimals(grossE18, ORACLE_DECIMALS, outDecimals);
        amountOut = gross.mulDiv(10_000 - spreadBps, 10_000);

        if (amountOut < receipt.minAmountOut) {
            revert SlippageExceeded(amountOut, receipt.minAmountOut);
        }

        uint256 reserveAvailable = IERC20(receipt.tokenOut).balanceOf(address(this));
        if (reserveAvailable < amountOut) {
            revert InsufficientReserves(receipt.tokenOut, amountOut, reserveAvailable);
        }

        // Effects before interactions.
        executed[requestId] = true;

        // Pay the recipient named in the receipt (canonical).
        IERC20(receipt.tokenOut).safeTransfer(receipt.recipient, amountOut);

        // Tell TGH the spot route is settled. Will revert if TGH receipt is
        // not in MINTED state (e.g., already settled), which gives us extra
        // belt-and-braces against state machine confusion.
        TELARANA_HUB_HOOK.markGatewayAtomicFxSwapSettled(requestId, amountOut);

        emit SpotFxExecuted(
            requestId,
            receipt.routeId,
            receipt.recipient,
            receipt.tokenOut,
            receipt.amount,
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

        if (enabled) {
            uint8 outDecimals = IERC20Metadata(token).decimals();
            if (outDecimals > MAX_TOKEN_DECIMALS) revert TokenDecimalsTooLarge(token, outDecimals);
            tokenDecimals[token] = outDecimals;
            emit TokenDecimalsStored(token, outDecimals);
        } else {
            delete tokenDecimals[token];
        }
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

    /// @dev Decimal-normalization helper modeled on Synthetix v3
    ///      `Price.scale/scaleTo`, using OZ `Math.mulDiv` for the multiply
    ///      and divide branches.
    function _scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) {
            return amount.mulDiv(10 ** uint256(toDecimals - fromDecimals), 1);
        }
        return amount.mulDiv(1, 10 ** uint256(fromDecimals - toDecimals));
    }
}
