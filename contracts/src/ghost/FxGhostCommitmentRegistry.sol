// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title FxGhostCommitmentRegistry
/// @notice Commitment/nullifier registry for Ghost Mode v1.
///
/// Data flow:
///   Bufi Wallet + RO-KYC pass
///       |
///       v
///   FxGhostSpokeRouter ---- registerCommitment ----> this registry
///       |
///       v
///   CCTP / hub action
///
///   Future withdrawal/proof router ---- consumeNullifier ----> this registry
///
/// V1 intentionally does not embed a production ZK verifier. It gives the
/// protocol stable commitment/nullifier storage and admin-set root metadata so
/// verifier integration can be added without changing the spoke entry surface.
contract FxGhostCommitmentRegistry {
    struct CommitmentRecord {
        bytes32 routeId;
        address account;
        address beneficiary;
        address token;
        uint256 amount;
        bytes32 metadataRef;
        uint64 registeredAt;
    }

    struct RootRecord {
        bool active;
        uint64 validUntil;
        bytes32 metadataRef;
    }

    address public owner;

    mapping(address recorder => bool allowed) public commitmentRecorders;
    mapping(address consumer => bool allowed) public nullifierConsumers;
    mapping(bytes32 commitment => bool registered) public commitmentRegistered;
    mapping(bytes32 commitment => CommitmentRecord record) private _commitments;
    mapping(bytes32 nullifierHash => bool consumed) public nullifierConsumed;
    mapping(bytes32 root => RootRecord record) public roots;

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroCommitment();
    error ZeroNullifier();
    error ZeroRoot();
    error UnauthorizedCommitmentRecorder(address recorder);
    error UnauthorizedNullifierConsumer(address consumer);
    error DuplicateCommitment(bytes32 commitment);
    error DuplicateNullifier(bytes32 nullifierHash);

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event GhostCommitmentRecorderSet(address indexed recorder, bool allowed);
    event GhostNullifierConsumerSet(address indexed consumer, bool allowed);
    event GhostRootSet(bytes32 indexed root, bool active, uint64 validUntil, bytes32 metadataRef);
    event GhostCommitmentRegistered(
        bytes32 indexed commitment,
        bytes32 indexed routeId,
        address indexed account,
        address beneficiary,
        address token,
        uint256 amount,
        bytes32 metadataRef
    );
    event GhostNullifierConsumed(bytes32 indexed nullifierHash, address indexed consumer);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnerTransferred(address(0), initialOwner);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setCommitmentRecorder(address recorder, bool allowed) external onlyOwner {
        if (recorder == address(0)) revert ZeroAddress();
        commitmentRecorders[recorder] = allowed;
        emit GhostCommitmentRecorderSet(recorder, allowed);
    }

    function setNullifierConsumer(address consumer, bool allowed) external onlyOwner {
        if (consumer == address(0)) revert ZeroAddress();
        nullifierConsumers[consumer] = allowed;
        emit GhostNullifierConsumerSet(consumer, allowed);
    }

    function setRoot(bytes32 root, bool active, uint64 validUntil, bytes32 metadataRef) external onlyOwner {
        if (root == bytes32(0)) revert ZeroRoot();
        roots[root] = RootRecord({active: active, validUntil: validUntil, metadataRef: metadataRef});
        emit GhostRootSet(root, active, validUntil, metadataRef);
    }

    function commitment(bytes32 commitment_) external view returns (CommitmentRecord memory record) {
        record = _commitments[commitment_];
    }

    function registerCommitment(
        bytes32 commitment_,
        bytes32 routeId,
        address account,
        address beneficiary,
        address token,
        uint256 amount,
        bytes32 metadataRef
    ) external {
        if (!commitmentRecorders[msg.sender]) revert UnauthorizedCommitmentRecorder(msg.sender);
        if (commitment_ == bytes32(0)) revert ZeroCommitment();
        if (account == address(0) || beneficiary == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (commitmentRegistered[commitment_]) revert DuplicateCommitment(commitment_);

        commitmentRegistered[commitment_] = true;
        _commitments[commitment_] = CommitmentRecord({
            routeId: routeId,
            account: account,
            beneficiary: beneficiary,
            token: token,
            amount: amount,
            metadataRef: metadataRef,
            registeredAt: uint64(block.timestamp)
        });

        emit GhostCommitmentRegistered(commitment_, routeId, account, beneficiary, token, amount, metadataRef);
    }

    function consumeNullifier(bytes32 nullifierHash) external {
        if (!nullifierConsumers[msg.sender]) revert UnauthorizedNullifierConsumer(msg.sender);
        if (nullifierHash == bytes32(0)) revert ZeroNullifier();
        if (nullifierConsumed[nullifierHash]) revert DuplicateNullifier(nullifierHash);
        nullifierConsumed[nullifierHash] = true;
        emit GhostNullifierConsumed(nullifierHash, msg.sender);
    }
}
