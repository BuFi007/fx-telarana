// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockStablecoin
/// @notice Parameterized ERC-20 stand-in for the regulated stablecoin basket
///         (AUDF, BRLA, JPYC, KRW1, MXNB, PHPC, ZCHF) on Arc testnet, deployed
///         only where issuer-canonical contracts do not yet exist.
/// @dev    Mirrors mainnet behavior closely:
///           * decimals are fixed at construction (issuer-matched: 6 or 18)
///           * ERC-2612 permit for Permit2-compatible flows
///           * Owner-only `mint` for deterministic test setup
///           * Optional public `faucet()` for self-serve testnet liquidity,
///             gated by `faucetOpen` so we can close it pre-mainnet rehearsal.
///         Lives in `test-helpers/` and is NEVER reachable from a mainnet
///         deploy script — see `docs/DEPLOY_MAINNET_HUB.md` §3 for the
///         mock-to-real switching policy (env-var driven, not code change).
contract MockStablecoin is ERC20, ERC20Burnable, ERC20Permit, Ownable {
    uint8 private immutable _decimals;

    /// @notice When true, anyone can call `faucet()`; when false, only owner can mint.
    bool public faucetOpen;

    /// @notice Per-call faucet payout, expressed in whole-token units (decimal-adjusted on payout).
    uint256 public constant FAUCET_WHOLE_TOKENS = 1_000;

    event FaucetStateChanged(bool open);
    event FaucetClaimed(address indexed to, uint256 amount);

    error FaucetClosed();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(owner_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Owner mint for test fixtures. Production token issuers all permission mint
    ///         to a single role; we mimic with Ownable for simplicity.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Self-serve testnet faucet. Pays out `FAUCET_WHOLE_TOKENS` units adjusted
    ///         to the token's decimals (so 1000 JPYC at 18 dec = 1000 * 1e18,
    ///         1000 MXNB at 6 dec = 1000 * 1e6). Off when `faucetOpen == false`.
    function faucet() external {
        if (!faucetOpen) revert FaucetClosed();
        uint256 amount = FAUCET_WHOLE_TOKENS * (10 ** _decimals);
        _mint(msg.sender, amount);
        emit FaucetClaimed(msg.sender, amount);
    }

    function setFaucetOpen(bool open) external onlyOwner {
        faucetOpen = open;
        emit FaucetStateChanged(open);
    }
}
