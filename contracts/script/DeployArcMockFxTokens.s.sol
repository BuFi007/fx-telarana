// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice One-shot deploy of mock fiat-backed stables for Phase A spot
///         markets on Arc testnet. JPYC + MXNB + CHFC. Real issuer assets
///         arrive via Hyperlane issuer-route in a later phase.
contract DeployArcMockFxTokens is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        MockERC20 jpyc = new MockERC20("Mock JPYC", "JPYC", 6);
        MockERC20 mxnb = new MockERC20("Mock MXNB", "MXNB", 6);
        MockERC20 chfc = new MockERC20("Mock CHFC", "CHFC", 6);

        // Seed deployer with a generous mock supply for liquidity bootstrap.
        // 1_000_000 atomic units per token = 1.0 of each token.
        jpyc.mint(deployer, 1_000_000_000);
        mxnb.mint(deployer, 1_000_000_000);
        chfc.mint(deployer, 1_000_000_000);
        vm.stopBroadcast();

        console2.log("=========================================");
        console2.log("Mock fiat-stable tokens (Phase A, Arc):");
        console2.log("=========================================");
        console2.log("JPYC", address(jpyc));
        console2.log("MXNB", address(mxnb));
        console2.log("CHFC", address(chfc));
    }
}
