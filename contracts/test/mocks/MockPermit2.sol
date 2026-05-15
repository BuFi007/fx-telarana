// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @notice Minimal Permit2 mock — just enough surface for FxRouter unit tests.
/// @dev    Does NOT verify the Permit2 signature (router-layer tests are not
///         responsible for proving Permit2 itself). The Router's intent
///         signature is fully verified via OZ SignatureChecker — that's the
///         auth-critical path. The Permit2 path on real chains is the
///         deterministic canonical contract.
///
///         Behavior:
///         * `permitTransferFrom` simply pulls `transferDetails.requestedAmount`
///           of `permit.permitted.token` from `owner` to `transferDetails.to`
///           using the ERC-20 allowance the test pre-grants on the mock.
contract MockPermit2 is ISignatureTransfer {
    using SafeERC20 for IERC20;

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(uint256(0xDEADBEEF));
    }

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /*signature*/
    ) external override {
        if (transferDetails.requestedAmount > permit.permitted.amount) {
            revert InvalidAmount(permit.permitted.amount);
        }
        IERC20(permit.permitted.token).safeTransferFrom(
            owner, transferDetails.to, transferDetails.requestedAmount
        );
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory,
        SignatureTransferDetails calldata,
        address,
        bytes32,
        string calldata,
        bytes calldata
    ) external pure override {
        revert("not implemented");
    }

    function permitTransferFrom(
        PermitBatchTransferFrom memory,
        SignatureTransferDetails[] calldata,
        address,
        bytes calldata
    ) external pure override {
        revert("not implemented");
    }

    function permitWitnessTransferFrom(
        PermitBatchTransferFrom memory,
        SignatureTransferDetails[] calldata,
        address,
        bytes32,
        string calldata,
        bytes calldata
    ) external pure override {
        revert("not implemented");
    }

    function invalidateUnorderedNonces(uint256, uint256) external pure override {}

    function nonceBitmap(address, uint256) external pure override returns (uint256) {
        return 0;
    }
}
