// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Deploys PSE's `poseidon-solidity` PoseidonT3 + PoseidonT4 libraries
///         to their canonical deterministic addresses on any EVM chain that
///         has the Arachnid CREATE2 deployer at 0x4e59b44847B379578588920cA78FbF26c0B4956C.
///
///         The vendored `.sol` files under `contracts/lib/poseidon-solidity/`
///         compile to ~29 KB (T3) and ~32 KB (T4) at our project's
///         `optimizer_runs=200`, both over EIP-170's 24,576-byte limit.
///         PSE ships *pre-compiled* init code in their npm package
///         (poseidon-solidity version 0.0.5) that produces a ~23.5 KB runtime
///         under EIP-170. We copy that init code verbatim from
///         `script/poseidon/PoseidonT{3,4}.data`, then send it to the
///         Arachnid deployer with a known salt — the (salt, init-code,
///         deployer) triple is fixed by PSE so the resulting addresses
///         are deterministic across every chain Arachnid is on.
///
/// Canonical addresses:
///   PoseidonT3 → 0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93
///   PoseidonT4 → 0x4443338EF595F44e0121df4C21102677B142ECF0
///
/// Idempotent: if both addresses already have code, the script skips the
/// deployment and returns success. Otherwise it deploys whichever is
/// missing and asserts the post-deploy bytecode is non-empty.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — funded on Fuji (small balance is enough; the
///                          tx target is the Arachnid deployer).
contract DeployPoseidonFuji is Script {
    /// Arachnid's deterministic deployer (live on every major EVM testnet
    /// and most mainnets).
    address constant ARACHNID_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// PSE canonical addresses. Match what 0xbow/Semaphore/Tornado deploy.
    address constant POSEIDON_T3_CANONICAL = 0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93;
    address constant POSEIDON_T4_CANONICAL = 0x4443338EF595F44e0121df4C21102677B142ECF0;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Sanity: Arachnid must be live on this chain.
        require(
            ARACHNID_DEPLOYER.code.length > 0,
            "DeployPoseidonFuji: Arachnid CREATE2 deployer not present on this chain"
        );

        // Read PSE-published init-code data files. Each file is a hex
        // string starting with `0x`, where the first 32 bytes (64 hex
        // chars after `0x`) are the salt and the rest is the init code.
        // We pass the whole thing as calldata to the Arachnid deployer.
        string memory t3Hex = vm.readFile("script/poseidon/PoseidonT3.data");
        string memory t4Hex = vm.readFile("script/poseidon/PoseidonT4.data");
        bytes memory t3Data = vm.parseBytes(t3Hex);
        bytes memory t4Data = vm.parseBytes(t4Hex);

        vm.startBroadcast(pk);
        _deployIfMissing(POSEIDON_T3_CANONICAL, t3Data, "PoseidonT3");
        _deployIfMissing(POSEIDON_T4_CANONICAL, t4Data, "PoseidonT4");
        vm.stopBroadcast();

        console2.log("===========================================");
        console2.log("PSE Poseidon canonical libs (Fuji)");
        console2.log("===========================================");
        console2.log("PoseidonT3 ", POSEIDON_T3_CANONICAL);
        console2.log("PoseidonT4 ", POSEIDON_T4_CANONICAL);
        console2.log("");
        console2.log("Wire foundry.toml `libraries` to these addresses");
        console2.log("before running DeployPrivacyHookFuji.s.sol.");
    }

    function _deployIfMissing(address target, bytes memory data, string memory label) internal {
        if (target.code.length > 0) {
            console2.log(string.concat(label, " already deployed at canonical address (skipping)"));
            return;
        }
        (bool ok, ) = ARACHNID_DEPLOYER.call(data);
        require(ok, string.concat(label, ": Arachnid call failed"));
        require(target.code.length > 0, string.concat(label, ": code not present after deploy"));
        console2.log(string.concat(label, " deployed"));
    }
}
