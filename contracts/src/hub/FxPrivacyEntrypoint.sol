// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Entrypoint} from "privacy-pools/contracts/Entrypoint.sol";

/// @title FxPrivacyEntrypoint
/// @notice fx-Telaraña Privacy Pool router. Slice 1: identical surface to
///         the vendored {Entrypoint} (0xbow privacy-pools-core, Apache-2.0,
///         audited). Carved out as a separate contract so slice 3 can add
///         `relayCrossCurrency()` (USDC→EURC shielded swap via FxSwapHook +
///         Uniswap V4 fallback) without re-vendoring.
contract FxPrivacyEntrypoint is Entrypoint {
    // Slice 3 will add:
    //   function relayCrossCurrency(
    //       IPrivacyPool.Withdrawal calldata _withdrawal,
    //       ProofLib.WithdrawProof  calldata _proof,
    //       uint256 _scope,
    //       address _outputAsset,
    //       bytes   calldata _routerData
    //   ) external nonReentrant;
}
