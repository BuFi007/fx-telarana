// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxOracleV2} from "../src/hub/FxOracleV2.sol";
import {FxOracle} from "../src/hub/FxOracle.sol";

/// @notice Deploy FxOracleV2 on Arc Testnet with Chainlink fallback,
///         then migrate all existing Pyth + RedStone feed configs from
///         the Sprint-1 FxOracle.
///
///         After deployment:
///         1. Register Chainlink aggregator addresses per token
///         2. Deploy new FxPerpClearinghouse pointing to this oracle
///         3. Re-register all perp markets on the new clearinghouse
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY    funded on Arc, must be DEFAULT_ADMIN_ROLE
///   ARC_FX_ORACLE_V1        (default: Sprint-1 oracle 0xf9b035...)
///   ARC_PYTH                (default: 0x2880aB...)
contract DeployFxOracleV2 is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_ORACLE_V1 = 0xf9b0356A31BC7125e2eD0DADf8b5957860d42c78;
    address internal constant DEFAULT_PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;

    // Sprint-1 oracle config
    uint256 internal constant MAX_ORACLE_AGE = 300;    // 5 min
    uint256 internal constant MAX_DEVIATION_BPS = 50;  // 0.50%
    uint256 internal constant MAX_CONFIDENCE_BPS = 50; // 0.50%
    uint256 internal constant CHAINLINK_MAX_AGE = 3600; // 1 hour (Chainlink push frequency)

    // All tokens that have Pyth feeds on the Sprint-1 oracle
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant JPYC = 0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a;
    address internal constant MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address internal constant CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
    address internal constant AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;

    error WrongChain(uint256 chainId);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address pyth = vm.envOr("ARC_PYTH", DEFAULT_PYTH);
        FxOracle v1 = FxOracle(vm.envOr("ARC_FX_ORACLE_V1", DEFAULT_ORACLE_V1));

        console2.log("=== Deploying FxOracleV2 on Arc Testnet ===");
        console2.log("deployer:", deployer);
        console2.log("pyth:", pyth);
        console2.log("v1 oracle:", address(v1));

        vm.startBroadcast(pk);

        // 1. Deploy FxOracleV2
        FxOracleV2 v2 = new FxOracleV2(
            pyth,
            deployer,
            MAX_ORACLE_AGE,
            MAX_DEVIATION_BPS,
            MAX_CONFIDENCE_BPS,
            CHAINLINK_MAX_AGE
        );

        console2.log("FxOracleV2 deployed:", address(v2));

        // 2. Migrate Pyth feeds from v1
        address[6] memory tokens = [USDC, EURC, JPYC, MXNB, CIRBTC, AUDF];
        for (uint256 i = 0; i < tokens.length; i++) {
            bytes32 pythFeed = v1.pythFeedOf(tokens[i]);
            bool inverted = v1.pythFeedInvertedOf(tokens[i]);
            if (pythFeed != bytes32(0)) {
                v2.setPythFeedConfig(tokens[i], pythFeed, inverted);
                console2.log("  Migrated Pyth feed:", tokens[i]);
            }
        }

        // 3. Migrate RedStone feeds from v1
        for (uint256 i = 0; i < tokens.length; i++) {
            bytes32 redstoneFeed = v1.redstoneFeedOf(tokens[i]);
            if (redstoneFeed != bytes32(0)) {
                v2.setRedstoneFeed(tokens[i], redstoneFeed);
                console2.log("  Migrated RedStone feed:", tokens[i]);
            }
        }

        // 4. Chainlink feeds — set when aggregator addresses are known.
        //    For now, log placeholders. Register post-deploy via:
        //    v2.setChainlinkFeed(AUDF, <AUD/USD aggregator>)
        //    v2.setChainlinkFeed(USDC, <USDC/USD aggregator>)
        //    v2.setChainlinkFeed(EURC, <EUR/USD aggregator>)
        //    etc.
        console2.log("");
        console2.log("=== Chainlink feeds: register post-deploy ===");
        console2.log("  v2.setChainlinkFeed(AUDF, <AUD/USD aggregator>)");
        console2.log("  v2.setChainlinkFeed(USDC, <USDC/USD aggregator>)");
        console2.log("  v2.setChainlinkFeed(EURC, <EUR/USD aggregator>)");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Next steps ===");
        console2.log("1. Register Chainlink aggregator addresses per token");
        console2.log("2. Deploy new FxPerpClearinghouse with oracle:", address(v2));
        console2.log("3. Re-register all 5 perp markets on new clearinghouse");
        console2.log("4. Update packages/contracts/src/index.ts with new addresses");
    }
}
