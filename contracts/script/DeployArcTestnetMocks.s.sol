// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

/// @notice Deploys the mock stablecoin basket on Arc testnet, standing in for
///         issuer-canonical contracts until the real ones land on the production
///         Hub (Avalanche C-Chain mainnet — most of these are natively live there).
///
/// Basket (per `docs/DEPLOY_MAINNET_HUB.md` §3.2):
///   mAUDF (6 dec)   — Forte AUDF stand-in
///   mJPYC (18 dec)  — JPYC Inc JPYC stand-in (mirrors MAINNET decimals, NOT Sepolia's 6)
///   mMXNB (6 dec)   — Bitso/Juno MXNB stand-in
///   mZCHF (18 dec)  — Frankencoin ZCHF stand-in (no CCIP integration in this phase)
///
/// KRW1 omitted — decimals pending on-chain probe via Avalanche mainnet
///   `cast call 0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318 decimals()`.
/// PHPC + BRLA dropped from Phase 3 basket entirely — see `docs/BLOCKED_PAIRS.md`
///   §Excluded from Phase 3 basket.
///
/// Required env:
///   ARC_TESTNET_RPC                — Arc testnet RPC
///   DEPLOYER_PRIVATE_KEY           — funded via faucet.circle.com
///
/// Optional env:
///   MOCK_OWNER                     — defaults to deployer; transfer to multisig if desired
///   MOCK_OPEN_FAUCETS              — "true" to open faucets immediately (testnet self-serve);
///                                    omit / "false" to require explicit owner mint
///
/// Output:
///   Logs all addresses to stdout in a JSON-friendly format. Pipe into
///   `deployments/arc-testnet-mocks.json` after the broadcast completes:
///     forge script ... 2>&1 | tee /tmp/mock.log
///     scripts/parse-mock-deploy.sh /tmp/mock.log > deployments/arc-testnet-mocks.json
contract DeployArcTestnetMocks is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("MOCK_OWNER", deployer);
        bool openFaucets = vm.envOr("MOCK_OPEN_FAUCETS", false);

        console2.log("======== fx-Telarana Arc Testnet Mock Stablecoins ========");
        console2.log("deployer        ", deployer);
        console2.log("mock owner      ", owner);
        console2.log("faucets open?   ", openFaucets);
        console2.log("=========================================================");

        vm.startBroadcast(pk);

        MockStablecoin mAUDF = new MockStablecoin("Mock AUDF (test)", "mAUDF", 6,  owner);
        MockStablecoin mJPYC = new MockStablecoin("Mock JPYC (test)", "mJPYC", 18, owner);
        MockStablecoin mMXNB = new MockStablecoin("Mock MXNB (test)", "mMXNB", 6,  owner);
        MockStablecoin mZCHF = new MockStablecoin("Mock ZCHF (test)", "mZCHF", 18, owner);

        if (openFaucets && owner == deployer) {
            mAUDF.setFaucetOpen(true);
            mJPYC.setFaucetOpen(true);
            mMXNB.setFaucetOpen(true);
            mZCHF.setFaucetOpen(true);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("======== Deployed mock stablecoins ========");
        console2.log("mAUDF (6  dec):", address(mAUDF));
        console2.log("mJPYC (18 dec):", address(mJPYC));
        console2.log("mMXNB (6  dec):", address(mMXNB));
        console2.log("mZCHF (18 dec):", address(mZCHF));
        console2.log("===========================================");
        console2.log("");
        console2.log("Next step: persist these to deployments/arc-testnet-mocks.json");
        console2.log("and update packages/sdk/src/addresses/index.ts ChainId.ArcTestnet.tokens map.");

        // Emit a copy-paste-friendly JSON skeleton for the operator.
        console2.log("");
        console2.log("---BEGIN JSON SKELETON---");
        console2.log('{');
        console2.log('  "network": "arc-testnet",');
        console2.log('  "chainId": 5042002,');
        console2.log('  "deployer":', deployer);
        console2.log('  "owner":', owner);
        console2.log('  "mocks": {');
        console2.log('    "mAUDF":', address(mAUDF));
        console2.log('    "mJPYC":', address(mJPYC));
        console2.log('    "mMXNB":', address(mMXNB));
        console2.log('    "mZCHF":', address(mZCHF));
        console2.log('  }');
        console2.log('}');
        console2.log("---END JSON SKELETON---");
    }
}
