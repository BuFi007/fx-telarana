// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBufiKycPass} from "../interfaces/IBufiKycPass.sol";
import {FxGhostCommitmentRegistry} from "./FxGhostCommitmentRegistry.sol";

interface IFxGhostCctpSpoke {
    function circleTokenAllowed(address token) external view returns (bool allowed);
    function enterHub(address token, uint256 amount, address beneficiary, bytes calldata hubCalldata)
        external
        payable
        returns (bytes32 messageNonce);
}

/// @title FxGhostSpokeRouter
/// @notice Pass-gated Ghost Mode wrapper over the Circle-only FxSpoke.
///
/// Data flow:
///   Bufi Wallet with RO-KYC pass
///       |
///       v
///   FxGhostSpokeRouter -- hasValidPass/passLevel --> IBufiKycPass
///       |
///       +-- register commitment ------------------> FxGhostCommitmentRegistry
///       |
///       +-- transfer Circle token + enterHub -----> FxSpoke / CCTP
///       |
///       v
///   Hub receives explicit Ghost beneficiary + hub calldata
contract FxGhostSpokeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct GhostRoute {
        address token;
        uint8 minPassLevel;
        bool enabled;
        bytes32 metadataRef;
    }

    address public owner;
    IFxGhostCctpSpoke public immutable SPOKE;
    IBufiKycPass public immutable PASS_VERIFIER;
    FxGhostCommitmentRegistry public immutable COMMITMENT_REGISTRY;

    mapping(bytes32 routeId => GhostRoute route) private _ghostRoutes;

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroCommitment();
    error InvalidRoute(bytes32 routeId);
    error RouteDisabled(bytes32 routeId);
    error UnsupportedRouteToken(bytes32 routeId, address token);
    error InvalidPass(address account, uint8 level, uint8 minLevel);
    error InvalidMinPassLevel(uint8 minPassLevel);

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event GhostRouteConfigured(
        bytes32 indexed routeId, address indexed token, uint8 minPassLevel, bool enabled, bytes32 metadataRef
    );
    event GhostSpokeEntered(
        bytes32 indexed messageNonce,
        bytes32 indexed routeId,
        bytes32 indexed commitment,
        address account,
        address beneficiary,
        address token,
        uint256 amount,
        uint8 passLevel,
        bytes32 metadataRef
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address spoke_, address passVerifier_, address commitmentRegistry_, address initialOwner) {
        if (
            spoke_ == address(0) || passVerifier_ == address(0) || commitmentRegistry_ == address(0)
                || initialOwner == address(0)
        ) revert ZeroAddress();
        SPOKE = IFxGhostCctpSpoke(spoke_);
        PASS_VERIFIER = IBufiKycPass(passVerifier_);
        COMMITMENT_REGISTRY = FxGhostCommitmentRegistry(commitmentRegistry_);
        owner = initialOwner;
        emit OwnerTransferred(address(0), initialOwner);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function ghostRoute(bytes32 routeId) external view returns (GhostRoute memory route) {
        route = _ghostRoutes[routeId];
    }

    function setGhostRoute(bytes32 routeId, address token, uint8 minPassLevel, bool enabled, bytes32 metadataRef)
        external
        onlyOwner
    {
        if (routeId == bytes32(0)) revert InvalidRoute(routeId);
        if (token == address(0)) revert ZeroAddress();
        if (minPassLevel == 0) revert InvalidMinPassLevel(minPassLevel);
        if (!SPOKE.circleTokenAllowed(token)) revert UnsupportedRouteToken(routeId, token);

        _ghostRoutes[routeId] =
            GhostRoute({token: token, minPassLevel: minPassLevel, enabled: enabled, metadataRef: metadataRef});
        emit GhostRouteConfigured(routeId, token, minPassLevel, enabled, metadataRef);
    }

    function enterHubGhost(
        bytes32 routeId,
        bytes32 commitment,
        uint256 amount,
        address beneficiary,
        bytes calldata hubCalldata
    ) external payable nonReentrant returns (bytes32 messageNonce) {
        GhostRoute memory route = _validatedRoute(routeId);
        if (commitment == bytes32(0)) revert ZeroCommitment();
        if (amount == 0) revert ZeroAmount();
        if (beneficiary == address(0)) revert ZeroAddress();

        uint8 level = _validatePass(msg.sender, route.minPassLevel);

        COMMITMENT_REGISTRY.registerCommitment(
            commitment, routeId, msg.sender, beneficiary, route.token, amount, route.metadataRef
        );

        IERC20(route.token).safeTransferFrom(msg.sender, address(this), amount);
        _ensureApproval(IERC20(route.token), address(SPOKE), amount);

        messageNonce = SPOKE.enterHub{value: msg.value}(route.token, amount, beneficiary, hubCalldata);

        emit GhostSpokeEntered(
            messageNonce, routeId, commitment, msg.sender, beneficiary, route.token, amount, level, route.metadataRef
        );
    }

    function _validatedRoute(bytes32 routeId) internal view returns (GhostRoute memory route) {
        route = _ghostRoutes[routeId];
        if (route.token == address(0)) revert InvalidRoute(routeId);
        if (!route.enabled) revert RouteDisabled(routeId);
        if (!SPOKE.circleTokenAllowed(route.token)) revert UnsupportedRouteToken(routeId, route.token);
    }

    function _validatePass(address account, uint8 minPassLevel) internal view returns (uint8 level) {
        level = PASS_VERIFIER.passLevel(account);
        if (!PASS_VERIFIER.hasValidPass(account) || level < minPassLevel) {
            revert InvalidPass(account, level, minPassLevel);
        }
    }

    function _ensureApproval(IERC20 token, address spender, uint256 needed) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current < needed) {
            if (current != 0) token.forceApprove(spender, 0);
            token.forceApprove(spender, type(uint256).max);
        }
    }
}
