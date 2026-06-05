// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ITurboFeeVault} from "../interfaces/ITurboFeeVault.sol";

/// @notice The Arc-side cross-hub rail (FxHubMessageReceiver.relayToRemoteHub, Stage-6 live): pulls
///         USDC from the caller and pushes it to the configured remote hub via Circle Gateway.
interface IHubRelay {
    function relayToRemoteHub(uint256 amount) external;
}

/// @title  FxYieldRelay — P3: cross-hub LP fee-yield distribution
/// @notice Closes the gap in cross-chain-yield-spec.md: "TurboFeeVault lives on Arc; Fuji LPs cannot
///         claim yield today." Spoke LPs stake (via their spoke adapter) into the canonical Arc
///         TurboFeeVault through this relay, which holds ONE TurboFeeVault position and sub-accounts
///         each cross-hub LP's pro-rata trading-fee yield (a second-layer Synthetix rewardPerShare).
///         On claim, the relay pulls the LP's yield from TurboFeeVault and pushes it to the LP's home
///         hub through the existing `relayToRemoteHub` Gateway rail. Yield delivery is permissionless.
///
/// @dev    COMPLIANCE LAW (yield-machine-spec.md): this is the RETAIL LP yield surface, and it is
///         RWA-CLEAN BY CONSTRUCTION — it only ever moves USDC TRADING-FEE yield out of TurboFeeVault.
///         It holds no USYC, calls no Teller, and is not the FxReserveYieldRouter. USYC-derived yield
///         can never reach an LP through this path: `retailAssets ∩ USYC = ∅` holds because USYC is
///         simply absent from this contract. (Retail's Morpho base yield, if any, stays par-pure in
///         SharedFxVault, also untouched here.)
///
///         The one inherent off-chain step is Circle's Gateway attestation that authorizes the mint on
///         the destination hub (`relayMintFromRemote`) — a property of native USDC, verified on-chain
///         by the GatewayMinter, not a trusted server call. The Arc-side push is fully on-chain.
contract FxYieldRelay is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SPOKE_ROLE = keccak256("SPOKE_ROLE"); // spoke adapters that register LP deposits

    IERC20 public immutable USDC;
    ITurboFeeVault public immutable FEE_VAULT;
    IHubRelay public hub; // FxHubMessageReceiver for the destination hub

    // --- second-layer Synthetix sub-accounting over our single TurboFeeVault position ---
    uint256 public totalSubShares; // == our TurboFeeVault share balance
    uint256 public rewardPerSubShareStored; // 1e18-scaled
    mapping(bytes32 lpKey => uint256) public subShares;
    mapping(bytes32 lpKey => uint256) public lpRewardPerSharePaid;
    mapping(bytes32 lpKey => uint256) public lpRewards;
    mapping(bytes32 lpKey => uint32) public homeChainOf;

    error ZeroAmount();
    error ZeroAddress();
    error HubNotSet();
    error InsufficientSubShares(uint256 requested, uint256 available);
    error NothingToClaim();

    event HubSet(address indexed hub);
    event Staked(uint32 indexed homeChain, address indexed lp, uint256 assets, uint256 subShares);
    event Unstaked(uint32 indexed homeChain, address indexed lp, uint256 subShares, uint256 assets);
    event YieldRelayed(uint32 indexed homeChain, address indexed lp, uint256 amount);

    constructor(IERC20 _usdc, ITurboFeeVault _feeVault, address admin) {
        if (address(_usdc) == address(0) || address(_feeVault) == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        USDC = _usdc;
        FEE_VAULT = _feeVault;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Identity key for a cross-hub LP: (home chain, LP address on that chain).
    function lpKey(uint32 homeChain, address lp) public pure returns (bytes32) {
        return keccak256(abi.encode(homeChain, lp));
    }

    /*//////////////////////////////////////////////////////////////
                           STAKE / UNSTAKE (SPOKE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Stake `assets` USDC into TurboFeeVault on behalf of a cross-hub LP. Caller (a spoke
    ///         adapter) must hold the bridged USDC and SPOKE_ROLE.
    function stakeFor(uint32 homeChain, address lp, uint256 assets)
        external
        onlyRole(SPOKE_ROLE)
        nonReentrant
        returns (uint256 newSubShares)
    {
        if (assets == 0) revert ZeroAmount();
        if (lp == address(0)) revert ZeroAddress();
        bytes32 k = lpKey(homeChain, lp);
        _sync();
        _updateLp(k);

        USDC.safeTransferFrom(msg.sender, address(this), assets);
        USDC.forceApprove(address(FEE_VAULT), assets);
        newSubShares = FEE_VAULT.deposit(assets); // TurboFeeVault mints shares to this relay

        subShares[k] += newSubShares;
        totalSubShares += newSubShares;
        homeChainOf[k] = homeChain;
        emit Staked(homeChain, lp, assets, newSubShares);
    }

    /// @notice Unstake `subShareAmt` of an LP's principal and push the USDC to its home hub via Gateway.
    function unstakeFor(uint32 homeChain, address lp, uint256 subShareAmt)
        external
        onlyRole(SPOKE_ROLE)
        nonReentrant
        returns (uint256 assets)
    {
        if (subShareAmt == 0) revert ZeroAmount();
        if (address(hub) == address(0)) revert HubNotSet();
        bytes32 k = lpKey(homeChain, lp);
        if (subShares[k] < subShareAmt) revert InsufficientSubShares(subShareAmt, subShares[k]);
        _sync();
        _updateLp(k);

        subShares[k] -= subShareAmt;
        totalSubShares -= subShareAmt;
        assets = FEE_VAULT.withdraw(subShareAmt); // USDC returns to this relay

        _pushHome(homeChain, lp, assets);
        emit Unstaked(homeChain, lp, subShareAmt, assets);
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM (PERMISSIONLESS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deliver a cross-hub LP's accrued fee yield to its home hub. Permissionless: the LP is
    ///         fixed by (homeChain, lp), so anyone can trigger delivery — the funds can only go home.
    function claimYieldFor(uint32 homeChain, address lp) external nonReentrant returns (uint256 amount) {
        if (address(hub) == address(0)) revert HubNotSet();
        bytes32 k = lpKey(homeChain, lp);
        _sync();
        _updateLp(k);
        amount = lpRewards[k];
        if (amount == 0) revert NothingToClaim();
        lpRewards[k] = 0;
        _pushHome(homeChain, lp, amount);
        emit YieldRelayed(homeChain, lp, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice An LP's claimable fee yield in USDC (incl. TurboFeeVault yield not yet synced in).
    function pendingYieldFor(uint32 homeChain, address lp) external view returns (uint256) {
        bytes32 k = lpKey(homeChain, lp);
        return lpRewards[k] + (subShares[k] * (_currentRewardPerSubShare() - lpRewardPerSharePaid[k])) / 1e18;
    }

    function _currentRewardPerSubShare() internal view returns (uint256 rps) {
        rps = rewardPerSubShareStored;
        if (totalSubShares > 0) {
            uint256 pend = FEE_VAULT.pendingYield(address(this));
            rps += (pend * 1e18) / totalSubShares;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/
    function setHub(IHubRelay hub_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(hub_) == address(0)) revert ZeroAddress();
        hub = hub_;
        emit HubSet(address(hub_));
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Pull this relay's pending TurboFeeVault yield into the sub-share reward pool.
    function _sync() internal {
        if (totalSubShares == 0) return;
        if (FEE_VAULT.pendingYield(address(this)) == 0) return;
        uint256 got = FEE_VAULT.claimYield();
        if (got > 0) rewardPerSubShareStored += (got * 1e18) / totalSubShares;
    }

    function _updateLp(bytes32 k) internal {
        uint256 owed = (subShares[k] * (rewardPerSubShareStored - lpRewardPerSharePaid[k])) / 1e18;
        if (owed > 0) lpRewards[k] += owed;
        lpRewardPerSharePaid[k] = rewardPerSubShareStored;
    }

    /// @dev Push `amount` USDC to the LP's home hub through the Gateway relay rail.
    function _pushHome(uint32, /* homeChain (single remote hub per relay in P3) */ address, /* lp */ uint256 amount)
        internal
    {
        USDC.forceApprove(address(hub), amount);
        hub.relayToRemoteHub(amount); // hub pulls USDC + initiates the cross-hub Gateway move
        USDC.forceApprove(address(hub), 0);
    }
}
