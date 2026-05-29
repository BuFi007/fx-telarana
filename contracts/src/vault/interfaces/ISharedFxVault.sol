// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISharedFxVault
/// @notice Surface that allowlisted FxSwapHooks call to source JIT liquidity from,
///         and settle fills back into, a single shared reserve vault.
/// @dev    Lender (senior) capital is USDC supplied to Morpho and is NEVER used for
///         fills in v1 — see SharedFxVault. Fills draw from the protocol-funded
///         JUNIOR buffer only (FX inventory + earmarked junior USDC), which takes all
///         market-making PnL first. Crediting of swap inputs is balance-based; the
///         hook is NEVER trusted to self-report amounts for accounting (only for the
///         pre-fill cap check).
interface ISharedFxVault {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event FillFunded(address indexed hook, address indexed outToken, uint256 outAmount, uint256 usdcNotional);
    event InflowRecorded(address indexed hook, address indexed inToken, uint256 credited);
    event HookAllowed(address indexed hook, bool allowed);
    event JuniorFunded(address indexed token, uint256 amount);
    event JuniorWithdrawn(address indexed token, uint256 amount, address to);
    event CapsUpdated(uint16 perSwapCapBps, uint16 perBlockCapBps, uint16 maxOracleMoveBps);
    event HotReserveUpdated(uint16 hotReservePctBps);
    event MorphoSupplied(uint256 assets);
    event MorphoWithdrawn(uint256 assets);

    /*//////////////////////////////////////////////////////////////
                            HOOK FILL SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Send `outAmount` of `outToken` to the v4 PoolManager so the calling
    ///         hook can settle a fill. HOOK_ROLE only, paused-gated, nonReentrant. The vault
    ///         prices the USDC notional ITSELF (USDC-out = amount; FX-out = oracle) and enforces
    ///         per-swap + per-block caps on it — the hook is never trusted for the notional.
    /// @param outToken      token the trader receives (USDC for FX→USDC swaps, else the FX token)
    /// @param outAmount     amount of outToken to push to the PoolManager
    /// @param poolManager   the v4 PoolManager (must equal the vault's canonical PoolManager)
    function fundFill(address outToken, uint256 outAmount, address poolManager) external;

    /// @notice Credit any untracked balance of `inToken` (the swap input the hook just
    ///         `take`-d to this vault) to the junior buffer. Balance-based — measures
    ///         the real delta, never trusts a reported amount. HOOK_ROLE only.
    /// @return credited the amount newly credited to the junior buffer
    function recordInflow(address inToken) external returns (uint256 credited);

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC earmarked to the junior buffer (funds USDC-out fills).
    function juniorUsdc() external view returns (uint256);

    /// @notice Junior-owned inventory of an FX token (funds FX-out fills).
    function juniorTokenBalance(address token) external view returns (uint256);

    /// @notice True if `hook` is allowlisted to source liquidity.
    function isAllowedHook(address hook) external view returns (bool);

    /// @notice The vault's ERC4626 underlying asset (USDC).
    function asset() external view returns (address);
}
