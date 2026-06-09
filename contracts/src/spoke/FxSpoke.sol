// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFxSpoke} from "../interfaces/IFxSpoke.sol";
import {ITokenMessengerV2, IMessageTransmitterV2} from "../interfaces/ICctp.sol";

/// @title FxSpoke
/// @notice Per-spoke-chain entrypoint to the fx-Telaraña Hub.
///
/// CCTP scope:
///   * Circle assets only: USDC and EURC where Circle supports CCTP for the route.
///   * The constructor token is the initial USDC-style asset; governance can
///     add EURC with `setCircleTokenAllowed` when Circle supports that route.
///   * Non-Circle assets must use Hyperlane/issuer routes, never this adapter.
///   * `beneficiary` is the Hub-side position owner. Public mode → user's
///     EOA/SCA. Ghost Mode → Bufi Ghost router/action account.
///
/// The `hookData` carried by CCTP V2 is `abi.encode(beneficiary, hubCalldata)`,
/// which `FxHubMessageReceiver` re-derives on the destination and matches via
/// keccak. Any tamper invalidates the hub call.
contract FxSpoke is IFxSpoke {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    ITokenMessengerV2 public immutable TOKEN_MESSENGER;
    IERC20 public immutable USDC;
    address public immutable HUB_RECEIVER; // destination Hub receiver, encoded as bytes32 for CCTP
    uint32 public immutable ARC_DOMAIN; // destination Hub CCTP domain; legacy getter name
    address public owner;

    /// @notice Circle assets accepted by this spoke. CCTP remains Circle-only:
    ///         USDC and EURC where the route is supported by Circle.
    mapping(address token => bool allowed) public circleTokenAllowed;

    /// @notice Trusted relayers permitted to settle hub→spoke CCTP exits (F-25).
    ///         `exitHub` is otherwise a bearer claim: the hub burns with
    ///         `mintRecipient = FxSpoke`, so without this gate ANY caller could
    ///         front-run a public Circle attestation and redirect the freshly
    ///         minted USDC to an arbitrary recipient. The exit flow is an
    ///         operational (protocol-run) redistribution, not a user action, so
    ///         it is gated to the owner + an allowlisted relayer set.
    mapping(address relayer => bool allowed) public exitRelayer;

    event ExitRelayerSet(address indexed relayer, bool allowed);

    /// @notice Default max-fee in USDC (6 decimals) the user is willing to pay
    ///         CCTP V2 for fast transport. Configurable per call via `enterHubWithFee`.
    uint256 public constant DEFAULT_MAX_FEE = 1_000; // 0.001 USDC

    /// @notice CCTP V2 finality threshold. 2000 = standard finalized; lower is faster.
    uint32 public constant FINALITY_FAST = 1000;
    uint32 public constant FINALITY_FINALIZED = 2000;

    error UnsupportedFinality(uint32 threshold);
    error NotOwner();
    error NotExitRelayer();

    /*//////////////////////////////////////////////////////////////
                                CTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address tokenMessenger, address usdc, address hubReceiver, uint32 arcDomain) {
        if (tokenMessenger == address(0) || usdc == address(0) || hubReceiver == address(0)) {
            revert UnsupportedToken(address(0));
        }
        TOKEN_MESSENGER = ITokenMessengerV2(tokenMessenger);
        USDC = IERC20(usdc);
        HUB_RECEIVER = hubReceiver;
        ARC_DOMAIN = arcDomain;
        owner = msg.sender;
        circleTokenAllowed[usdc] = true;
        emit CircleTokenAllowedSet(usdc, true);
    }

    function setCircleTokenAllowed(address token, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        if (token == address(0)) revert UnsupportedToken(address(0));
        circleTokenAllowed[token] = allowed;
        emit CircleTokenAllowedSet(token, allowed);
    }

    function setExitRelayer(address relayer, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        if (relayer == address(0)) revert InvalidBeneficiary();
        exitRelayer[relayer] = allowed;
        emit ExitRelayerSet(relayer, allowed);
    }

    function transferOwner(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert InvalidBeneficiary();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                ENTRY
    //////////////////////////////////////////////////////////////*/

    function enterHub(address token, uint256 amount, address beneficiary, bytes calldata hubCalldata)
        external
        payable
        returns (bytes32 messageNonce)
    {
        return enterHubWithFee(token, amount, beneficiary, hubCalldata, DEFAULT_MAX_FEE, FINALITY_FAST);
    }

    /// @notice Same as enterHub but lets the caller tune CCTP V2 maxFee + threshold.
    function enterHubWithFee(
        address token,
        uint256 amount,
        address beneficiary,
        bytes calldata hubCalldata,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) public returns (bytes32 messageNonce) {
        if (!circleTokenAllowed[token]) revert UnsupportedToken(token);
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (minFinalityThreshold != FINALITY_FAST && minFinalityThreshold != FINALITY_FINALIZED) {
            revert UnsupportedFinality(minFinalityThreshold);
        }

        IERC20 circleToken = IERC20(token);
        circleToken.safeTransferFrom(msg.sender, address(this), amount);
        _ensureApproval(circleToken, address(TOKEN_MESSENGER), amount);

        bytes memory hookData = abi.encode(beneficiary, hubCalldata);

        TOKEN_MESSENGER.depositForBurnWithHook(
            amount,
            ARC_DOMAIN,
            _toBytes32(HUB_RECEIVER),
            token,
            _toBytes32(HUB_RECEIVER), // destinationCaller: only the hub receiver may dispatch
            maxFee,
            minFinalityThreshold,
            hookData
        );

        // CCTP V2 generates the message nonce internally and we cannot read it back
        // synchronously; we use keccak(spoke, sender, hookData) as a local-tracking key.
        messageNonce = keccak256(abi.encode(address(this), msg.sender, hookData, block.number));

        emit Entered(messageNonce, beneficiary, token, amount, hubCalldata);
    }

    /*//////////////////////////////////////////////////////////////
                                EXIT
    //////////////////////////////////////////////////////////////*/

    function exitHub(bytes calldata cctpMessage, bytes calldata attestation, address recipient) external {
        _exitHubForToken(cctpMessage, attestation, recipient, address(USDC));
    }

    function exitHubForToken(bytes calldata cctpMessage, bytes calldata attestation, address recipient, address token)
        external
    {
        _exitHubForToken(cctpMessage, attestation, recipient, token);
    }

    function _exitHubForToken(bytes calldata cctpMessage, bytes calldata attestation, address recipient, address token)
        internal
    {
        // F-25: only the owner or an allowlisted relayer may settle an exit.
        // Without this, `exitHub` is a permissionless bearer claim — anyone could
        // front-run the legitimate relayer with a public Circle attestation and
        // redirect the minted USDC (which is sent to this spoke) to themselves.
        if (msg.sender != owner && !exitRelayer[msg.sender]) revert NotExitRelayer();
        if (recipient == address(0)) revert InvalidBeneficiary();
        if (!circleTokenAllowed[token]) revert UnsupportedToken(token);

        IERC20 circleToken = IERC20(token);
        uint256 balBefore = circleToken.balanceOf(address(this));

        // Get the MessageTransmitter address. CCTP V2 wires it inside TokenMessenger;
        // expose a getter call rather than a separate immutable to keep deploy simple.
        IMessageTransmitterV2 mt = _getMessageTransmitter();
        mt.receiveMessage(cctpMessage, attestation);

        uint256 received = circleToken.balanceOf(address(this)) - balBefore;
        if (received == 0) revert UnsupportedToken(token);

        circleToken.safeTransfer(recipient, received);
        emit Exited(bytes32(0), recipient, token, received);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _ensureApproval(IERC20 token, address spender, uint256 needed) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current < needed) {
            if (current != 0) token.forceApprove(spender, 0);
            token.forceApprove(spender, type(uint256).max);
        }
    }

    /// @notice Read MessageTransmitter from TokenMessenger's storage. CCTP V2 keeps the
    ///         transmitter address on the BaseTokenMessenger; expose via a known selector.
    ///         If the selector differs on a given CCTP deployment, override at deploy time
    ///         by reading from a known immutable on `TOKEN_MESSENGER` via a custom getter.
    function _getMessageTransmitter() internal view returns (IMessageTransmitterV2) {
        (bool ok, bytes memory data) =
            address(TOKEN_MESSENGER).staticcall(abi.encodeWithSignature("localMessageTransmitter()"));
        require(ok && data.length >= 32, "messageTransmitter() failed");
        return IMessageTransmitterV2(abi.decode(data, (address)));
    }
}
