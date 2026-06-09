// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title KawaiiRebateVault
/// @notice Vested USDC rebates for loyal Kawaii VIP holders — the on-chain B4
///         "anti-mimetic retention" anchor (a kept, non-positional good) for the
///         TurboFeeVault P3 fee-redistribution track. Cyber-kantics: the keeper is
///         the off-chain oracle (Humean/Kantian power → rebate); this vault is the
///         decisionist + pull-payment settlement layer that makes the promise safe.
///
/// @dev Trust + safety model (the "not a liability" requirements):
///      - PULL-PAYMENT ONLY. Holders `claim()`; the vault never pushes funds, so a
///        hostile recipient cannot grief a batch and there is no forced send.
///      - SOLVENCY INVARIANT: `USDC.balanceOf(this) >= unallocated + totalOutstanding`
///        holds after every call. The allocator can only allocate against
///        already-FUNDED `unallocated` USDC, so the keeper can never promise a
///        rebate with no backing. This is the core property; see the invariant test.
///      - LINEAR VESTING per holder. Top-ups fold the still-unvested remainder into
///        a fresh window (deterministic, path-independent accrual — never call-
///        frequency dependent, never over-pays).
///      - Roles separate money-in (FUNDER) from who-gets-what (ALLOCATOR = keeper),
///        with a PAUSER guardian circuit breaker (decisionist exception) and an
///        admin that can only ever sweep the *surplus above reserved* — never owed
///        funds. Immutable (no proxy) to minimise surface.
contract KawaiiRebateVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant REBATE_FUNDER_ROLE = keccak256("REBATE_FUNDER_ROLE");
    bytes32 public constant REBATE_ALLOCATOR_ROLE = keccak256("REBATE_ALLOCATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable USDC;
    /// @notice Linear vesting window (seconds) applied to each allocation. Immutable.
    uint256 public immutable VEST_DURATION;

    /// @notice Funded-but-not-yet-allocated USDC. The backing pool the allocator
    ///         draws against; an allocation reverts if it exceeds this.
    uint256 public unallocated;
    /// @notice Σ allocated − Σ claimed: USDC owed to holders (vested or vesting).
    uint256 public totalOutstanding;

    /// @dev Per-holder vesting schedule. `released` tracks how much of the CURRENT
    ///      schedule has already been folded into `vested` (keeps accrual idempotent).
    struct Schedule {
        uint256 principal; // current schedule size (vesting + vested-of-this-schedule)
        uint256 released; // portion of `principal` already accrued into `vested`
        uint64 start; // schedule start timestamp
    }

    mapping(address => Schedule) public schedules;
    mapping(address => uint256) public vested; // cumulative vested (claimable + claimed)
    mapping(address => uint256) public claimed; // cumulative claimed

    // --- stats ---
    uint256 public totalFunded;
    uint256 public totalAllocated;
    uint256 public totalClaimed;

    // --- F-9: per-epoch allocation cap (defense-in-depth vs a compromised
    //     allocator key; complements role-splitting at deploy). 0 == unlimited.
    uint256 public constant ALLOCATION_EPOCH = 1 days;
    uint256 public allocationCapPerEpoch;
    uint256 public epochAllocated;
    uint64 public epochStart;

    // --- F-27: grace before stale (never-claimed) allocations can be clawed
    //     back to the backing pool. Measured in whole vest windows so it is
    //     always far longer than the vesting period itself.
    uint256 public constant STALE_CLAWBACK_EPOCHS = 12;

    event Funded(address indexed funder, uint256 amount, uint256 unallocated);
    event Allocated(address indexed holder, uint256 amount, uint64 vestStart);
    event Claimed(address indexed holder, uint256 amount);
    event SurplusRecovered(address indexed to, uint256 amount);
    event AllocationCapSet(uint256 capPerEpoch);
    event AllocationClawedBack(address indexed holder, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error LengthMismatch();
    error InsufficientUnallocated(uint256 requested, uint256 available);
    error NothingToClaim();
    error AllocationCapExceeded(uint256 requested, uint256 remainingThisEpoch);
    error NotStale(address holder, uint256 eligibleAt);

    /// @param _usdc          settlement token (USDC, 6dp).
    /// @param _vestDuration  linear vest window in seconds (>0).
    /// @param _admin         DEFAULT_ADMIN_ROLE holder (grants the other roles).
    constructor(IERC20 _usdc, uint256 _vestDuration, address _admin) {
        if (address(_usdc) == address(0) || _admin == address(0)) revert ZeroAddress();
        if (_vestDuration == 0) revert ZeroAmount();
        USDC = _usdc;
        VEST_DURATION = _vestDuration;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // ─── Funding (money in) ──────────────────────────────────────────

    /// @notice Top up the backing pool. Pull from the funder; raises `unallocated`.
    ///         Allowed while paused (adding backing is always safe).
    function fund(uint256 amount) external onlyRole(REBATE_FUNDER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Credit the ACTUAL received amount (balance delta), not the requested
        // amount — so a fee-on-transfer / non-standard token can never over-credit
        // `unallocated` and break solvency before allocation (codex audit HIGH-1).
        uint256 beforeBal = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = USDC.balanceOf(address(this)) - beforeBal;
        if (received == 0) revert ZeroAmount();
        unallocated += received;
        totalFunded += received;
        emit Funded(msg.sender, received, unallocated);
    }

    // ─── Allocation (who gets what — the keeper) ─────────────────────

    /// @notice Allocate a vested rebate to a holder. Draws `amount` from
    ///         `unallocated` (reverts if underfunded — the solvency guard), folds
    ///         the holder's still-unvested remainder into a fresh vest window.
    function allocate(address holder, uint256 amount)
        external
        onlyRole(REBATE_ALLOCATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        _allocate(holder, amount);
    }

    /// @notice Batch form. Same per-item guards; one tx for the keeper's run.
    function allocateBatch(address[] calldata holders, uint256[] calldata amounts)
        external
        onlyRole(REBATE_ALLOCATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (holders.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < holders.length; i++) {
            _allocate(holders[i], amounts[i]);
        }
    }

    function _allocate(address holder, uint256 amount) internal {
        // Reject zero + the vault itself — allocating to address(this) would strand
        // backed funds (the vault can't call claim()) outside recoverSurplus reach
        // (codex audit LOW-3). Misallocation to a non-claiming EOA stays a keeper-
        // correctness concern, mitigated by off-chain validation before allocate.
        if (holder == address(0) || holder == address(this)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > unallocated) revert InsufficientUnallocated(amount, unallocated);

        // F-9: rolling per-epoch allocation cap. Bounds how much a single
        // (compromised) allocator key can move out in any window. 0 == unlimited.
        uint256 cap = allocationCapPerEpoch;
        if (cap != 0) {
            uint256 spent = block.timestamp >= uint256(epochStart) + ALLOCATION_EPOCH ? 0 : epochAllocated;
            if (spent + amount > cap) revert AllocationCapExceeded(amount, cap > spent ? cap - spent : 0);
            if (spent == 0) epochStart = uint64(block.timestamp);
            epochAllocated = spent + amount;
        }

        _accrue(holder); // bank everything vested under the OLD schedule first

        Schedule storage s = schedules[holder];
        uint256 remainingUnvested = s.principal - s.released; // not yet vested
        s.principal = remainingUnvested + amount; // remainder + new amount…
        s.released = 0;
        s.start = uint64(block.timestamp); // …vest linearly from now

        unallocated -= amount; // ← solvency: only ever allocate funded USDC
        totalOutstanding += amount;
        totalAllocated += amount;
        emit Allocated(holder, amount, uint64(block.timestamp));
    }

    // ─── Claim (pull payment) ────────────────────────────────────────

    /// @notice Claim all vested-but-unclaimed rebate. Pull-only; CEI + guard.
    /// @dev F-11: `claim()` is intentionally NOT `whenNotPaused`. Already-vested
    ///      rebates are fully backed (the solvency invariant holds), so the pause
    ///      circuit breaker must not censor funds already owed to holders — pause
    ///      only blocks NEW allocations/vesting (`allocate`/`allocateBatch`).
    function claim() external nonReentrant returns (uint256 amount) {
        _accrue(msg.sender);
        amount = vested[msg.sender] - claimed[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimed[msg.sender] += amount; // effects before interaction
        totalOutstanding -= amount;
        totalClaimed += amount;

        USDC.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ─── Views ───────────────────────────────────────────────────────

    /// @notice Vested-but-unclaimed USDC for a holder, as of now.
    function claimable(address holder) external view returns (uint256) {
        uint256 v = vested[holder] + (_vestedOfSchedule(holder, block.timestamp) - schedules[holder].released);
        return v - claimed[holder];
    }

    /// @notice Total still owed to a holder (vested + still-vesting − claimed).
    function owed(address holder) external view returns (uint256) {
        return (totalAllocatedTo(holder)) - claimed[holder];
    }

    /// @dev Lifetime allocated to a holder = already-vested + the live schedule's
    ///      not-yet-released principal. (vested already counts released-of-schedule.)
    function totalAllocatedTo(address holder) public view returns (uint256) {
        Schedule storage s = schedules[holder];
        return vested[holder] + (s.principal - s.released);
    }

    // ─── Guardian + admin ────────────────────────────────────────────

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Sweep ONLY the surplus above what's reserved (donations / rounding
    ///         dust). Can never touch `unallocated` or owed funds — solvency holds.
    function recoverSurplus(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = USDC.balanceOf(address(this));
        uint256 reserved = unallocated + totalOutstanding;
        uint256 surplus = bal > reserved ? bal - reserved : 0;
        if (surplus == 0) revert ZeroAmount();
        USDC.safeTransfer(to, surplus);
        emit SurplusRecovered(to, surplus);
    }

    /// @notice F-9: set the rolling per-epoch allocation cap (0 = unlimited).
    ///         Deployments should set a sane cap so one compromised allocator
    ///         key cannot move the entire unallocated pool in a single window.
    function setAllocationCapPerEpoch(uint256 capPerEpoch) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allocationCapPerEpoch = capPerEpoch;
        emit AllocationCapSet(capPerEpoch);
    }

    /// @notice F-27: claw a holder's never-claimed allocation back into the
    ///         backing pool once it is far past full vesting (a misallocation to
    ///         a non-claiming/typo'd/lost-key address would otherwise be stranded
    ///         in `totalOutstanding` forever, outside `recoverSurplus` reach).
    /// @dev    Solvency-preserving: moves `owed` from `totalOutstanding` to
    ///         `unallocated`; the token balance is unchanged. Only callable once
    ///         the holder's live schedule started ≥ `STALE_CLAWBACK_EPOCHS` vest
    ///         windows ago, so it can never touch funds a holder could still be
    ///         reasonably expected to claim.
    function clawbackStale(address holder)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        uint256 eligibleAt = uint256(schedules[holder].start) + VEST_DURATION * STALE_CLAWBACK_EPOCHS;
        if (block.timestamp < eligibleAt) revert NotStale(holder, eligibleAt);

        amount = totalAllocatedTo(holder) - claimed[holder];
        if (amount == 0) revert NothingToClaim();

        delete schedules[holder];
        vested[holder] = 0;
        claimed[holder] = 0;

        totalOutstanding -= amount;
        unallocated += amount;
        emit AllocationClawedBack(holder, amount);
    }

    // ─── Internal ────────────────────────────────────────────────────

    /// @dev Total vested of the CURRENT schedule as of `ts` (monotonic in ts).
    function _vestedOfSchedule(address holder, uint256 ts) internal view returns (uint256) {
        Schedule storage s = schedules[holder];
        if (s.principal == 0) return 0;
        uint256 elapsed = ts - s.start;
        if (elapsed >= VEST_DURATION) return s.principal; // full release at end → no dust trapped
        return (s.principal * elapsed) / VEST_DURATION;
    }

    /// @dev Bank newly-vested amount into `vested`. Idempotent + path-independent:
    ///      `newly` = vestedOfSchedule(now) − released, and released only grows.
    function _accrue(address holder) internal {
        uint256 v = _vestedOfSchedule(holder, block.timestamp);
        uint256 newly = v - schedules[holder].released;
        if (newly > 0) {
            schedules[holder].released = v;
            vested[holder] += newly;
        }
    }
}
