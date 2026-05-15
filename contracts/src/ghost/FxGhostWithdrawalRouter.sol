// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBufiKycPass} from "../interfaces/IBufiKycPass.sol";
import {IFxGhostWithdrawalVerifier} from "../interfaces/IFxGhostWithdrawalVerifier.sol";
import {FxGhostCommitmentRegistry} from "./FxGhostCommitmentRegistry.sol";

/// @title FxGhostWithdrawalRouter
/// @notice Proof/nullifier withdrawal scaffold for Ghost Mode v1.
///
/// Data flow:
///   Bufi Wallet pass account + offchain proof
///       |
///       v
///   FxGhostWithdrawalRouter -- hasValidPass/passLevel --> IBufiKycPass
///       |
///       +-- verify proof -----------------------------> IFxGhostWithdrawalVerifier
///       |
///       +-- consume nullifier ------------------------> FxGhostCommitmentRegistry
///       |
///       v
///   recipient receives token already held by this router
///
/// V1 does not embed a production ZK verifier and does not pull funds from
/// Morpho directly. It is a narrow payout router for balances made available to
/// the Ghost route by later action routers or settlement flows.
contract FxGhostWithdrawalRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct WithdrawalRoute {
        address token;
        uint8 minPassLevel;
        bool enabled;
        bytes32 metadataRef;
    }

    address public owner;
    IBufiKycPass public passVerifier;
    IFxGhostWithdrawalVerifier public withdrawalVerifier;
    FxGhostCommitmentRegistry public immutable COMMITMENT_REGISTRY;

    mapping(bytes32 routeId => WithdrawalRoute route) private _withdrawalRoutes;

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroRoot();
    error ZeroNullifier();
    error InvalidRoute(bytes32 routeId);
    error RouteDisabled(bytes32 routeId);
    error InvalidMinPassLevel(uint8 minPassLevel);
    error InvalidPass(address account, uint8 level, uint8 minLevel);
    error InvalidRoot(bytes32 root);
    error RootExpired(bytes32 root, uint64 validUntil);
    error InvalidWithdrawalProof(bytes32 nullifierHash);

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event GhostWithdrawalPassVerifierSet(address indexed verifier);
    event GhostWithdrawalVerifierSet(address indexed verifier);
    event GhostWithdrawalRouteConfigured(
        bytes32 indexed routeId, address indexed token, uint8 minPassLevel, bool enabled, bytes32 metadataRef
    );
    event GhostWithdrawalCompleted(
        bytes32 indexed nullifierHash,
        bytes32 indexed routeId,
        address indexed recipient,
        address token,
        uint256 amount,
        uint8 passLevel,
        bytes32 root,
        bytes32 metadataRef
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address passVerifier_, address withdrawalVerifier_, address commitmentRegistry_, address initialOwner) {
        if (
            passVerifier_ == address(0) || withdrawalVerifier_ == address(0) || commitmentRegistry_ == address(0)
                || initialOwner == address(0)
        ) revert ZeroAddress();
        passVerifier = IBufiKycPass(passVerifier_);
        withdrawalVerifier = IFxGhostWithdrawalVerifier(withdrawalVerifier_);
        COMMITMENT_REGISTRY = FxGhostCommitmentRegistry(commitmentRegistry_);
        owner = initialOwner;
        emit OwnerTransferred(address(0), initialOwner);
        emit GhostWithdrawalPassVerifierSet(passVerifier_);
        emit GhostWithdrawalVerifierSet(withdrawalVerifier_);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPassVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        passVerifier = IBufiKycPass(verifier);
        emit GhostWithdrawalPassVerifierSet(verifier);
    }

    function setWithdrawalVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        withdrawalVerifier = IFxGhostWithdrawalVerifier(verifier);
        emit GhostWithdrawalVerifierSet(verifier);
    }

    function withdrawalRoute(bytes32 routeId) external view returns (WithdrawalRoute memory route) {
        route = _withdrawalRoutes[routeId];
    }

    function setWithdrawalRoute(bytes32 routeId, address token, uint8 minPassLevel, bool enabled, bytes32 metadataRef)
        external
        onlyOwner
    {
        if (routeId == bytes32(0)) revert InvalidRoute(routeId);
        if (token == address(0)) revert ZeroAddress();
        if (minPassLevel == 0) revert InvalidMinPassLevel(minPassLevel);

        _withdrawalRoutes[routeId] =
            WithdrawalRoute({token: token, minPassLevel: minPassLevel, enabled: enabled, metadataRef: metadataRef});
        emit GhostWithdrawalRouteConfigured(routeId, token, minPassLevel, enabled, metadataRef);
    }

    function withdrawWithProof(
        bytes32 routeId,
        bytes32 root,
        bytes32 nullifierHash,
        address passAccount,
        address recipient,
        uint256 amount,
        bytes32 metadataRef,
        bytes calldata proof
    ) external nonReentrant returns (uint8 passLevel) {
        WithdrawalRoute memory route = _validatedRoute(routeId);
        _validatePublicInputs(root, nullifierHash, passAccount, recipient, amount);
        passLevel = _validatePass(passAccount, route.minPassLevel);
        _validateRoot(root);

        bool validProof = withdrawalVerifier.verifyGhostWithdrawal(
            root, nullifierHash, routeId, passAccount, route.token, amount, recipient, metadataRef, proof
        );
        if (!validProof) revert InvalidWithdrawalProof(nullifierHash);

        COMMITMENT_REGISTRY.consumeNullifier(nullifierHash);
        IERC20(route.token).safeTransfer(recipient, amount);

        emit GhostWithdrawalCompleted(
            nullifierHash, routeId, recipient, route.token, amount, passLevel, root, metadataRef
        );
    }

    function _validatedRoute(bytes32 routeId) internal view returns (WithdrawalRoute memory route) {
        route = _withdrawalRoutes[routeId];
        if (route.token == address(0)) revert InvalidRoute(routeId);
        if (!route.enabled) revert RouteDisabled(routeId);
    }

    function _validatePublicInputs(
        bytes32 root,
        bytes32 nullifierHash,
        address passAccount,
        address recipient,
        uint256 amount
    ) internal pure {
        if (root == bytes32(0)) revert ZeroRoot();
        if (nullifierHash == bytes32(0)) revert ZeroNullifier();
        if (passAccount == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
    }

    function _validateRoot(bytes32 root) internal view {
        (bool active, uint64 validUntil,) = COMMITMENT_REGISTRY.roots(root);
        if (!active) revert InvalidRoot(root);
        if (validUntil < block.timestamp) revert RootExpired(root, validUntil);
    }

    function _validatePass(address account, uint8 minPassLevel) internal view returns (uint8 level) {
        level = passVerifier.passLevel(account);
        if (!passVerifier.hasValidPass(account) || level < minPassLevel) {
            revert InvalidPass(account, level, minPassLevel);
        }
    }
}
