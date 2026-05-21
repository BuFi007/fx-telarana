// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TestnetFiatToken} from "../src/testnet/TestnetFiatToken.sol";

/// @notice Replaces the v0 mock-token deploy with the role-gated
///         `TestnetFiatToken` per Codex HIGH#4 (2026-05-16): the previous
///         `MockERC20` exposes unrestricted `mint` and `burn(address,uint256)`,
///         which means any testnet account can drain `FxSpotExecutor`'s
///         reserves.
///
///         The new tokens here:
///           * MINTER_ROLE-gated mint (initial admin only)
///           * Public `burn()` / `burnFrom()` (self / allowance-gated;
///             cannot burn anyone else's balance)
///           * 6 decimals to mirror current Circle-style fiat rails. The
///             v0.2 executor also supports non-6-dec tokenOut assets.
contract DeployArcTestnetFiatTokens is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("INITIAL_ADMIN", deployer);

        vm.startBroadcast(pk);
        TestnetFiatToken jpyc = new TestnetFiatToken("Testnet JPYC", "tJPYC", 6, admin);
        TestnetFiatToken mxnb = new TestnetFiatToken("Testnet MXNB", "tMXNB", 6, admin);
        TestnetFiatToken chfc = new TestnetFiatToken("Testnet CHFC", "tCHFC", 6, admin);

        // Seed deployer (the admin / minter) with bootstrap supply.
        // 1_000 atomic units * 1e6 = 1_000.000000 of each token.
        jpyc.mint(deployer, 1_000_000_000);
        mxnb.mint(deployer, 1_000_000_000);
        chfc.mint(deployer, 1_000_000_000);
        vm.stopBroadcast();

        console2.log("=========================================");
        console2.log("Testnet fiat-stable tokens (Phase A v0.2, Arc):");
        console2.log("=========================================");
        console2.log("tJPYC", address(jpyc));
        console2.log("tMXNB", address(mxnb));
        console2.log("tCHFC", address(chfc));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. setTokenEnabled(<each>) on FxSpotExecutor v0.2");
        console2.log("  2. approve + addLiquidity(<each>, seed)");
        console2.log("  3. Update BUFX SDK testnet-deployments + smoke");
    }
}
