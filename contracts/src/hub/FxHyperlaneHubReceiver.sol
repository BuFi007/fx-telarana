// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {
    IHyperlaneMailbox,
    IHyperlaneRecipient,
    IInterchainSecurityModule,
    ISpecifiesInterchainSecurityModule
} from "../interfaces/IHyperlane.sol";
import {IFxMarketRegistry} from "../interfaces/IFxMarketRegistry.sol";
import {FxHyperlaneIntentLib} from "../libraries/FxHyperlaneIntentLib.sol";

/// @title FxHyperlaneHubReceiver
/// @notice Hub-side acceptance layer for Hyperlane spoke intents.
///
/// ┌───────────────────────────────────────────────────────────────────────┐
/// │ Hyperlane Mailbox.handle(origin, sender, body)                        │
/// │   │                                                                   │
/// │   ├─► sender must be a registered FxSpokeIntentRouter                 │
/// │   ├─► body must decode to FxHyperlaneIntentLib.Intent v1              │
/// │   ├─► route + input token must be allowlisted for the origin domain   │
/// │   ├─► FxMarketRegistry.isPoolLive(loan, collateral) must be true      │
/// │   └─► nonce must be fresh; intent is stored for beneficiary execution │
/// │                                                                       │
/// │ executeIntent(id)                                                     │
/// │   ├─► token-funded: beneficiary pulls exact input into registry       │
/// │   └─► borrow: account-approved receiver borrows to beneficiary        │
/// │                                                                       │
/// │ executeRoutedIntent(id)                                               │
/// │   ├─► allowlisted Warp route has already delivered funds here         │
/// │   └─► route executes supply / collateral / repay for beneficiary      │
/// └───────────────────────────────────────────────────────────────────────┘
contract FxHyperlaneHubReceiver is
    IHyperlaneRecipient,
    ISpecifiesInterchainSecurityModule,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATIONS_ROLE = keccak256("OPERATIONS_ROLE");

    IHyperlaneMailbox public immutable MAILBOX;
    IFxMarketRegistry public immutable MARKET_REGISTRY;
    IInterchainSecurityModule private _interchainSecurityModule;

    enum IntentState {
        Unknown,
        Accepted,
        Executed,
        Cancelled
    }

    mapping(uint32 => mapping(bytes32 => bool)) public trustedSpokes;
    mapping(uint32 => mapping(address => mapping(address => bool))) public routeAssetAllowed;

    mapping(bytes32 => IntentState) private _intentState;
    mapping(bytes32 => FxHyperlaneIntentLib.Intent) private _intent;
    mapping(bytes32 => uint32) private _intentOrigin;
    mapping(bytes32 => bytes32) private _intentSender;

    error ZeroAddress();
    error NotMailbox(address caller);
    error UntrustedSpoke(uint32 origin, bytes32 sender);
    error InvalidIntent();
    error RouteAssetNotAllowed(uint32 origin, address route, address token);
    error DuplicateIntent(bytes32 intentId);
    error IntentNotAccepted(bytes32 intentId);
    error NotIntentBeneficiary(address beneficiary, address caller);
    error UnsupportedIntentAction(FxHyperlaneIntentLib.Action action);
    error TokenTransferShortfall(address token, uint256 expected, uint256 received);

    event InterchainSecurityModuleSet(address indexed module);
    event TrustedSpokeSet(uint32 indexed origin, bytes32 indexed sender, bool trusted);
    event RouteAssetSet(uint32 indexed origin, address indexed route, address indexed token, bool allowed);
    event IntentAccepted(
        bytes32 indexed intentId,
        uint32 indexed origin,
        bytes32 indexed sender,
        address beneficiary,
        FxHyperlaneIntentLib.Action action,
        address inputToken,
        uint256 inputAmount,
        address loanToken,
        address collateralToken,
        address route,
        bytes32 nonce
    );
    event IntentExecuted(
        bytes32 indexed intentId,
        address indexed beneficiary,
        FxHyperlaneIntentLib.Action action,
        address inputToken,
        uint256 inputAmount,
        uint256 shares
    );
    event RoutedIntentExecuted(
        bytes32 indexed intentId,
        uint32 indexed origin,
        address indexed route,
        address beneficiary,
        FxHyperlaneIntentLib.Action action,
        address inputToken,
        uint256 inputAmount,
        uint256 shares
    );
    event IntentCancelled(bytes32 indexed intentId, address indexed beneficiary);

    constructor(address mailbox_, address marketRegistry_, address initialAdmin) {
        if (mailbox_ == address(0) || marketRegistry_ == address(0) || initialAdmin == address(0)) {
            revert ZeroAddress();
        }

        MAILBOX = IHyperlaneMailbox(mailbox_);
        MARKET_REGISTRY = IFxMarketRegistry(marketRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATIONS_ROLE, initialAdmin);
    }

    function setInterchainSecurityModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _interchainSecurityModule = IInterchainSecurityModule(module);
        emit InterchainSecurityModuleSet(module);
    }

    function interchainSecurityModule() external view returns (IInterchainSecurityModule) {
        return _interchainSecurityModule;
    }

    function setTrustedSpoke(uint32 origin, bytes32 sender, bool trusted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (sender == bytes32(0)) revert ZeroAddress();
        trustedSpokes[origin][sender] = trusted;
        emit TrustedSpokeSet(origin, sender, trusted);
    }

    function setRouteAsset(uint32 origin, address route, address token, bool allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (route == address(0) || token == address(0)) revert ZeroAddress();
        routeAssetAllowed[origin][route][token] = allowed;
        emit RouteAssetSet(origin, route, token, allowed);
    }

    function pause() external onlyRole(OPERATIONS_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATIONS_ROLE) {
        _unpause();
    }

    function handle(uint32 origin, bytes32 sender, bytes calldata messageBody) external payable whenNotPaused {
        if (msg.sender != address(MAILBOX)) revert NotMailbox(msg.sender);
        if (!trustedSpokes[origin][sender]) revert UntrustedSpoke(origin, sender);

        FxHyperlaneIntentLib.Intent memory decoded = FxHyperlaneIntentLib.decode(messageBody);
        _validateIntent(origin, decoded);

        bytes32 intentId = FxHyperlaneIntentLib.intentId(origin, sender, decoded);
        if (_intentState[intentId] != IntentState.Unknown) revert DuplicateIntent(intentId);

        _intentState[intentId] = IntentState.Accepted;
        _intent[intentId] = decoded;
        _intentOrigin[intentId] = origin;
        _intentSender[intentId] = sender;

        emit IntentAccepted(
            intentId,
            origin,
            sender,
            decoded.beneficiary,
            decoded.action,
            decoded.inputToken,
            decoded.inputAmount,
            decoded.loanToken,
            decoded.collateralToken,
            decoded.route,
            decoded.nonce
        );
    }

    function executeIntent(bytes32 intentId) external nonReentrant {
        if (_intentState[intentId] != IntentState.Accepted) revert IntentNotAccepted(intentId);

        FxHyperlaneIntentLib.Intent memory current = _intent[intentId];
        if (msg.sender != current.beneficiary) revert NotIntentBeneficiary(current.beneficiary, msg.sender);

        _validateIntentForExecution(_intentOrigin[intentId], current);

        _intentState[intentId] = IntentState.Executed;
        uint256 shares =
            current.action == FxHyperlaneIntentLib.Action.Borrow ? _executeBorrow(current) : _pullAndExecute(current);

        emit IntentExecuted(
            intentId, current.beneficiary, current.action, current.inputToken, current.inputAmount, shares
        );
    }

    /// @notice Execute an accepted, token-funded intent using assets that a
    ///         trusted Hyperlane route has already delivered to this receiver.
    /// @dev    This is the Warp Route / transfer-and-call path. `msg.sender`
    ///         must be the allowlisted route recorded in the intent, and this
    ///         contract must already hold at least `inputAmount`.
    function executeRoutedIntent(bytes32 intentId) external nonReentrant {
        if (_intentState[intentId] != IntentState.Accepted) revert IntentNotAccepted(intentId);

        FxHyperlaneIntentLib.Intent memory current = _intent[intentId];
        if (!FxHyperlaneIntentLib.isTokenFunded(current.action)) {
            revert UnsupportedIntentAction(current.action);
        }
        if (msg.sender != current.route) {
            revert RouteAssetNotAllowed(_intentOrigin[intentId], msg.sender, current.inputToken);
        }

        _validateIntentForExecution(_intentOrigin[intentId], current);

        _intentState[intentId] = IntentState.Executed;
        uint256 shares = _executeFromReceiverBalance(current);

        emit RoutedIntentExecuted(
            intentId,
            _intentOrigin[intentId],
            current.route,
            current.beneficiary,
            current.action,
            current.inputToken,
            current.inputAmount,
            shares
        );
    }

    function cancelIntent(bytes32 intentId) external {
        if (_intentState[intentId] != IntentState.Accepted) revert IntentNotAccepted(intentId);

        FxHyperlaneIntentLib.Intent memory current = _intent[intentId];
        if (msg.sender != current.beneficiary) revert NotIntentBeneficiary(current.beneficiary, msg.sender);

        _intentState[intentId] = IntentState.Cancelled;
        emit IntentCancelled(intentId, current.beneficiary);
    }

    function intentState(bytes32 intentId) external view returns (IntentState) {
        return _intentState[intentId];
    }

    function intent(bytes32 intentId) external view returns (FxHyperlaneIntentLib.Intent memory) {
        return _intent[intentId];
    }

    function intentRoute(bytes32 intentId) external view returns (uint32 origin, bytes32 sender) {
        return (_intentOrigin[intentId], _intentSender[intentId]);
    }

    function _validateIntent(uint32 origin, FxHyperlaneIntentLib.Intent memory current) internal view {
        if (current.version != FxHyperlaneIntentLib.VERSION || current.nonce == bytes32(0)) revert InvalidIntent();
        if (
            current.beneficiary == address(0) || current.loanToken == address(0)
                || current.collateralToken == address(0)
        ) {
            revert ZeroAddress();
        }
        if (!MARKET_REGISTRY.isPoolLive(current.loanToken, current.collateralToken)) revert InvalidIntent();

        if (FxHyperlaneIntentLib.isTokenFunded(current.action)) {
            if (current.inputAmount == 0 || current.route == address(0)) revert InvalidIntent();
            if (current.inputToken != FxHyperlaneIntentLib.requiredInputToken(current)) revert InvalidIntent();
            if (!routeAssetAllowed[origin][current.route][current.inputToken]) {
                revert RouteAssetNotAllowed(origin, current.route, current.inputToken);
            }
        } else if (current.action == FxHyperlaneIntentLib.Action.Borrow) {
            if (current.inputToken != address(0) || current.inputAmount == 0 || current.route != address(0)) {
                revert InvalidIntent();
            }
        } else {
            revert UnsupportedIntentAction(current.action);
        }
    }

    function _validateIntentForExecution(uint32 origin, FxHyperlaneIntentLib.Intent memory current) internal view {
        if (current.version != FxHyperlaneIntentLib.VERSION || current.nonce == bytes32(0)) revert InvalidIntent();
        if (!MARKET_REGISTRY.isPoolLive(current.loanToken, current.collateralToken)) revert InvalidIntent();
        if (FxHyperlaneIntentLib.isTokenFunded(current.action)) {
            if (current.inputToken != FxHyperlaneIntentLib.requiredInputToken(current)) revert InvalidIntent();
            if (current.inputAmount == 0 || current.route == address(0)) revert InvalidIntent();
            if (!routeAssetAllowed[origin][current.route][current.inputToken]) {
                revert RouteAssetNotAllowed(origin, current.route, current.inputToken);
            }
        } else if (current.action == FxHyperlaneIntentLib.Action.Borrow) {
            if (current.inputToken != address(0) || current.inputAmount == 0 || current.route != address(0)) {
                revert InvalidIntent();
            }
        } else {
            revert UnsupportedIntentAction(current.action);
        }
    }

    function _pullAndExecute(FxHyperlaneIntentLib.Intent memory current) internal returns (uint256 shares) {
        IERC20 token = IERC20(current.inputToken);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(current.beneficiary, address(this), current.inputAmount);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received != current.inputAmount) {
            revert TokenTransferShortfall(current.inputToken, current.inputAmount, received);
        }

        token.forceApprove(address(MARKET_REGISTRY), current.inputAmount);
        if (current.action == FxHyperlaneIntentLib.Action.Supply) {
            shares = MARKET_REGISTRY.supply(
                current.loanToken, current.collateralToken, current.inputAmount, current.beneficiary
            );
        } else if (current.action == FxHyperlaneIntentLib.Action.SupplyCollateral) {
            MARKET_REGISTRY.supplyCollateral(
                current.loanToken, current.collateralToken, current.inputAmount, current.beneficiary
            );
        } else if (current.action == FxHyperlaneIntentLib.Action.Repay) {
            shares = MARKET_REGISTRY.repay(
                current.loanToken, current.collateralToken, current.inputAmount, current.beneficiary
            );
        } else {
            revert UnsupportedIntentAction(current.action);
        }
        token.forceApprove(address(MARKET_REGISTRY), 0);
    }

    function _executeFromReceiverBalance(FxHyperlaneIntentLib.Intent memory current) internal returns (uint256 shares) {
        IERC20 token = IERC20(current.inputToken);
        uint256 balance = token.balanceOf(address(this));
        if (balance < current.inputAmount) {
            revert TokenTransferShortfall(current.inputToken, current.inputAmount, balance);
        }

        token.forceApprove(address(MARKET_REGISTRY), current.inputAmount);
        shares = _executeFundedRegistryAction(current);
        token.forceApprove(address(MARKET_REGISTRY), 0);
    }

    function _executeFundedRegistryAction(FxHyperlaneIntentLib.Intent memory current)
        internal
        returns (uint256 shares)
    {
        if (current.action == FxHyperlaneIntentLib.Action.Supply) {
            shares = MARKET_REGISTRY.supply(
                current.loanToken, current.collateralToken, current.inputAmount, current.beneficiary
            );
        } else if (current.action == FxHyperlaneIntentLib.Action.SupplyCollateral) {
            MARKET_REGISTRY.supplyCollateral(
                current.loanToken, current.collateralToken, current.inputAmount, current.beneficiary
            );
        } else if (current.action == FxHyperlaneIntentLib.Action.Repay) {
            shares = MARKET_REGISTRY.repay(
                current.loanToken, current.collateralToken, current.inputAmount, current.beneficiary
            );
        } else {
            revert UnsupportedIntentAction(current.action);
        }
    }

    function _executeBorrow(FxHyperlaneIntentLib.Intent memory current) internal returns (uint256 shares) {
        shares = MARKET_REGISTRY.borrowDelegated(
            current.loanToken, current.collateralToken, current.inputAmount, current.beneficiary, current.beneficiary
        );
    }
}
