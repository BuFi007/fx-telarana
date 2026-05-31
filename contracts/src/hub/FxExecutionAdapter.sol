// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams as MorphoMarketParams} from "morpho-blue/interfaces/IMorpho.sol";

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
