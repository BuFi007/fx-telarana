// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

/// @notice Deploys the mock stablecoin basket on Arc testnet, standing in for
///         issuer-canonical contracts until the real ones land on Arc mainnet.
///
/// Basket (per `docs/DEPLOY_MAINNET_HUB.md` §3.2):
///   mAUDF (6 dec)   — Forte AUDF stand-in
///   mBRLA (18 dec)  — Avenia BRLA stand-in
///   mJPYC (18 dec)  — JPYC Inc JPYC stand-in (mirrors MAINNET decimals, NOT Sepolia's 6)
///   mMXNB (6 dec)   — Bitso/Juno MXNB stand-in
///   mPHPC (6 dec)   — Coins.PH PHPC stand-in (deploy until Arc avail confirmed)
///   mZCHF (18 dec)  — Frankencoin ZCHF stand-in (no CCIP integration in this phase)
///
/// KRW1 is omitted — decimals unconfirmed (BDACS pending reply). See `docs/BLOCKED_PAIRS.md`.
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
        MockStablecoin mBRLA = new MockStablecoin("Mock BRLA (test)", "mBRLA", 18, owner);
        MockStablecoin mJPYC = new MockStablecoin("Mock JPYC (test)", "mJPYC", 18, owner);
        MockStablecoin mMXNB = new MockStablecoin("Mock MXNB (test)", "mMXNB", 6,  owner);
        MockStablecoin mPHPC = new MockStablecoin("Mock PHPC (test)", "mPHPC", 6,  owner);
        MockStablecoin mZCHF = new MockStablecoin("Mock ZCHF (test)", "mZCHF", 18, owner);

        if (openFaucets && owner == deployer) {
            mAUDF.setFaucetOpen(true);
            mBRLA.setFaucetOpen(true);
            mJPYC.setFaucetOpen(true);
            mMXNB.setFaucetOpen(true);
            mPHPC.setFaucetOpen(true);
            mZCHF.setFaucetOpen(true);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("======== Deployed mock stablecoins ========");
        console2.log("mAUDF (6  dec):", address(mAUDF));
        console2.log("mBRLA (18 dec):", address(mBRLA));
        console2.log("mJPYC (18 dec):", address(mJPYC));
        console2.log("mMXNB (6  dec):", address(mMXNB));
        console2.log("mPHPC (6  dec):", address(mPHPC));
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
        console2.log('    "mBRLA":', address(mBRLA));
        console2.log('    "mJPYC":', address(mJPYC));
        console2.log('    "mMXNB":', address(mMXNB));
        console2.log('    "mPHPC":', address(mPHPC));
        console2.log('    "mZCHF":', address(mZCHF));
        console2.log('  }');
        console2.log('}');
        console2.log("---END JSON SKELETON---");
    }
}
