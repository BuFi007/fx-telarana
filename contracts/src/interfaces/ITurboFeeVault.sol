// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface ITurboFeeVault {
    function depositFee(address token, uint256 amount, bytes32 marketId) external;

    function deposit(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assets);
    function claimYield() external returns (uint256 claimed);

    function pendingYield(address user) external view returns (uint256);
    function totalDeposits() external view returns (uint256);
    function compositeApy() external view returns (uint256);

    event FeeDeposited(bytes32 indexed marketId, address token, uint256 amount, uint256 protocolShare, uint256 lpShare, uint256 insuranceShare);
    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 assets);
    event YieldClaimed(address indexed user, uint256 amount);
    event InsurancePayout(bytes32 indexed marketId, uint256 amount, string reason);
}
