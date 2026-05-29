// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ManualPriceFeed} from "../src/oracles/ManualPriceFeed.sol";

/// @notice Deploy the self-published CAD/USD + USDC/USD feeds for QCAD pricing via FxOracleV2's
///         Chainlink fallback. owner = KEEPER (canary). 8 decimals. CAD/USD=0.73, USDC/USD=1.00.
contract DeployManualFeeds is Script {
    address constant KEEPER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        ManualPriceFeed cad = new ManualPriceFeed(8, "CAD / USD", 73_000_000, KEEPER); // 0.73e8
        ManualPriceFeed usdc = new ManualPriceFeed(8, "USDC / USD", 100_000_000, KEEPER); // 1.00e8
        vm.stopBroadcast();
        console2.log("CAD_USD_FEED ", address(cad));
        console2.log("USDC_USD_FEED", address(usdc));
    }
}
