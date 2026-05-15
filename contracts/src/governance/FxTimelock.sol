// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title FxTimelock
/// @notice Thin wrapper over OZ `TimelockController` that fx-Telaraña uses as
///         the `DEFAULT_ADMIN_ROLE` holder on `FxOracle`, `FxMarketRegistry`,
///         and `FxLiquidator`.
///
/// @dev    Spec §2.5 originally named "Compound Timelock 0.5.16 vendored in
///         vendor/compound-timelock/". We deliberately chose OZ's
///         `TimelockController` instead:
///           - Same functional shape (queue/execute/cancel with min-delay).
///           - Already at ^0.8.20+ — no multi-pragma compiler dance.
///           - Already vendored under `lib/openzeppelin-contracts/`.
///           - Maintained, audited, and matches the rest of our OZ surface
///             (AccessControl, Pausable, ReentrancyGuardTransient).
///
///         Functional mapping (Compound → OZ):
///           - `delay`               → `getMinDelay()`
///           - `queueTransaction`    → `schedule` / `scheduleBatch`
///           - `executeTransaction`  → `execute` / `executeBatch`
///           - `cancelTransaction`   → `cancel`
///
/// Phase 3 spec §10.2:
///   - `DEFAULT_ADMIN_ROLE` on each admin contract = this Timelock (24-48h).
///   - `OPERATIONS_ROLE` = multisig (hot actions, no timelock).
///
/// Data flow:
///   governance proposer
///       |
///       v
///   FxTimelock -- schedule / execute --> FxOracle / FxMarketRegistry / FxLiquidator
///       |
///       v
///   delayed admin action becomes live after minDelay
contract FxTimelock is TimelockController {
    /// @param minDelay   Minimum delay in seconds. Phase 3 default = 24 hours.
    /// @param proposers  Addresses allowed to queue operations (typically the
    ///                   multisig or governance executor).
    /// @param executors  Addresses allowed to execute ready operations. Pass
    ///                   `address(0)` in the list to make execution open
    ///                   (any address can execute once delay elapses).
    /// @param admin      Optional initial admin (besides the timelock itself).
    ///                   Pass `address(0)` for self-administered timelock
    ///                   (recommended for production once bootstrapped).
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
