// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IFxMarginAccount} from "../perp/interfaces/IFxMarginAccount.sol";
import {IFxRouterSwapAdapter} from "./FxRouter.sol";

/// @title IFxExecutionAdapter
/// @notice Generalized execution adapter for the private-execution router
///         (`FxPrivacyEntrypoint.relayExecute`). The entrypoint transfers
///         `amount` of `asset` to the adapter BEFORE calling `execute`, then
///         the adapter performs its protocol action on behalf of `recipient`.
///
///         Trust boundary (mirrors the swap-adapter model): the entrypoint does
///         NOT trust the adapter's return value for accounting — it measures its
///         own sell-asset balance delta after the call. The adapter returns an
///         optional `(resultToken, resultAmount)` it has sent BACK to the
///         entrypoint to be forwarded to the recipient (e.g. a borrow's output);
///         for actions whose funds stay in the protocol (a supply) it returns
///         `(address(0), 0)`.
interface IFxExecutionAdapter {
    function execute(
        address asset,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external returns (address resultToken, uint256 resultAmount);
}

/// @title FxMorphoSupplyAdapter
/// @notice Registered execution adapter: supplies `amount` of `asset` into a
///         Morpho Blue market on behalf of `recipient`. Funds stay in Morpho
///         (no settle-back), so it returns (address(0), 0). The MarketParams are
///         carried in `data` and bound into the user's Groth16 proof context by
///         the entrypoint (`context = keccak256(Withdrawal, scope)`), so a relayer
///         cannot redirect the supply.
///
///         Caller-gated: only the privacy entrypoint may invoke `execute`
///         (the same hardening the swap adapter uses).
contract FxMorphoSupplyAdapter is IFxExecutionAdapter {
    using SafeERC20 for IERC20;

    IMorpho public immutable MORPHO;
    address public immutable ENTRYPOINT;

    error OnlyEntrypoint();
    error AssetMismatch(address asset, address loanToken);

    constructor(address _morpho, address _entrypoint) {
        MORPHO = IMorpho(_morpho);
        ENTRYPOINT = _entrypoint;
    }

    /// @inheritdoc IFxExecutionAdapter
    function execute(
        address asset,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external returns (address, uint256) {
        if (msg.sender != ENTRYPOINT) revert OnlyEntrypoint();

        MorphoMarketParams memory mp = abi.decode(data, (MorphoMarketParams));
        if (mp.loanToken != asset) revert AssetMismatch(asset, mp.loanToken);

        // Entrypoint already transferred `amount` of `asset` to this adapter.
        IERC20(asset).forceApprove(address(MORPHO), amount);
        MORPHO.supply(mp, amount, 0, recipient, "");

        // Supply stays in Morpho — nothing settles back to the entrypoint.
        return (address(0), 0);
    }
}

/// @title FxPerpMarginAdapter
/// @notice Registered execution adapter: funds perp MARGIN from a shielded note
///         for a detached executor (`recipient`), via `FxMarginAccount.depositMargin`.
///         This is the "private perp" primitive — the order settlement is a CLOB
///         with off-chain matching + signed orders, so a position is NOT opened in
///         one on-chain call. Instead we privately credit the detached executor's
///         margin; the executor then trades from that funded account (signing
///         orders), so the user's own wallet never posts margin or appears as the
///         on-chain trader. Funds stay in the margin account (no settle-back).
contract FxPerpMarginAdapter is IFxExecutionAdapter {
    using SafeERC20 for IERC20;

    IFxMarginAccount public immutable MARGIN;
    address public immutable ENTRYPOINT;
    IERC20 public immutable USDC;

    error OnlyEntrypoint();
    error NotUsdc(address asset);

    constructor(address _margin, address _entrypoint, address _usdc) {
        MARGIN = IFxMarginAccount(_margin);
        ENTRYPOINT = _entrypoint;
        USDC = IERC20(_usdc);
    }

    /// @inheritdoc IFxExecutionAdapter
    /// @param recipient the detached executor whose perp margin is credited
    function execute(address asset, uint256 amount, address recipient, bytes calldata)
        external
        returns (address, uint256)
    {
        if (msg.sender != ENTRYPOINT) revert OnlyEntrypoint();
        if (asset != address(USDC)) revert NotUsdc(asset);

        // depositMargin pulls `amount` from this adapter via transferFrom.
        USDC.forceApprove(address(MARGIN), amount);
        MARGIN.depositMargin(recipient, amount);

        // Margin stays in the account — nothing settles back.
        return (address(0), 0);
    }
}

/// @title FxSpotSwapAdapter
/// @notice Registered execution adapter: swap the shielded sell-asset into a
///         buy-token via the protocol swap adapter, settling the output BACK to
///         the entrypoint so `relayExecute` forwards the measured amount to the
///         recipient. Brings spot into the uniform relayExecute registry (one
///         execution path for the BufiOwnStackProvider). `data = abi.encode(buyToken, minBuyAmount)`.
contract FxSpotSwapAdapter is IFxExecutionAdapter {
    using SafeERC20 for IERC20;

    IFxRouterSwapAdapter public immutable SWAP;
    address public immutable ENTRYPOINT;

    error OnlyEntrypoint();
    error BuyTokenEqualsSell();

    constructor(address _swap, address _entrypoint) {
        SWAP = IFxRouterSwapAdapter(_swap);
        ENTRYPOINT = _entrypoint;
    }

    /// @inheritdoc IFxExecutionAdapter
    function execute(address asset, uint256 amount, address /*recipient*/, bytes calldata data)
        external
        returns (address, uint256)
    {
        if (msg.sender != ENTRYPOINT) revert OnlyEntrypoint();
        (address buyToken, uint256 minBuyAmount) = abi.decode(data, (address, uint256));
        if (buyToken == asset) revert BuyTokenEqualsSell();

        // The swap adapter expects the sell asset pre-transferred (same as the
        // entrypoint's relayCrossCurrency path). Deliver output to the ENTRYPOINT
        // so relayExecute measures + forwards it to the user recipient.
        IERC20(asset).safeTransfer(address(SWAP), amount);
        uint256 out = SWAP.swapExactInput(asset, buyToken, amount, minBuyAmount, ENTRYPOINT);

        // settle-back: relayExecute forwards min(measured, out) of buyToken.
        return (buyToken, out);
    }
}
