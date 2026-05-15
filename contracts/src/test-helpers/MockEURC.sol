// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Faucet-style mock EURC for testnets where Circle hasn't deployed the
///         real EURC contract. 6 decimals to match the production contract.
///         Mint is permissionless so users can pull test liquidity.
contract MockEURC is ERC20 {
    constructor() ERC20("Euro Coin (testnet)", "EURC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
