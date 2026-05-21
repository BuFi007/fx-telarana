// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TestnetFiatToken} from "../src/testnet/TestnetFiatToken.sol";

/// @notice Wave M2 (retry): deploy a we-control MXNB clone on Avalanche Fuji.
///         Mirrors the Arc-side tMXNB token at
///         `0xe8F76f90553F50E76731afbeF1ac83a9152fFBEb`:
///           * name = "Testnet MXNB"
///           * symbol = "tMXNB"
///           * decimals = 6
///           * MINTER_ROLE-gated mint
///           * Self / allowance burn via ERC20Burnable
///         Used because the live Bitso MXNB FiatToken at
///         `0xAB99d44185af87AeB08361588F00F59B0CE85eBb` has no public-mint
///         faucet and the keeper is not a minter — see M2 retry brief.
///
///         Initial admin/minter is the keeper for bootstrap. After deploy
///         the script grants DEFAULT_ADMIN_ROLE + MINTER_ROLE to ARC_TMXNB_ADMIN
///         (which on Arc currently is the same keeper). Caller is responsible
///         for renouncing the keeper's admin role later if a multisig handoff
///         is desired — keeping it for now matches the Arc-side posture
///         exactly so the two clones remain symmetric until Bitso handoff.
contract DeployFujiTestnetMxnb is Script {
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Arc tMXNB DEFAULT_ADMIN_ROLE holder; defaults to keeper for
        // symmetry with current Arc state.
        address newAdmin = vm.envOr("ARC_TMXNB_ADMIN", deployer);
        // Recipient of bootstrap supply — keeper by default.
        address mintRecipient = vm.envOr("MINT_RECIPIENT", deployer);
        uint256 mintAmount = vm.envOr("MINT_AMOUNT_RAW", uint256(1_000_000_000_000));

        vm.startBroadcast(pk);
        // Deploy with deployer as initial admin so we can mint before transfer.
        TestnetFiatToken mxnb = new TestnetFiatToken("Testnet MXNB", "tMXNB", 6, deployer);

        // Mint bootstrap supply to recipient (keeper for testing).
        mxnb.mint(mintRecipient, mintAmount);

        // Hand over administration to the Arc-tMXNB admin (same address on
        // current testnet, but the indirection lets a future Bitso handoff
        // flip just one env var). Skip role-transfer when newAdmin == deployer
        // to avoid no-op state changes that pollute the deploy artefact.
        if (newAdmin != deployer) {
            mxnb.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            mxnb.grantRole(MINTER_ROLE, newAdmin);
            mxnb.renounceRole(MINTER_ROLE, deployer);
            mxnb.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        }
        vm.stopBroadcast();

        console2.log("==============================================");
        console2.log("Wave M2 (retry) - Fuji MXNB clone deployed");
        console2.log("==============================================");
        console2.log("address      ", address(mxnb));
        console2.log("name         ", mxnb.name());
        console2.log("symbol       ", mxnb.symbol());
        console2.log("decimals     ", mxnb.decimals());
        console2.log("totalSupply  ", mxnb.totalSupply());
        console2.log("admin        ", newAdmin);
        console2.log("mintRecipient", mintRecipient);
        console2.log("mintAmount   ", mintAmount);
        console2.log("");
        console2.log("Next: Hyperlane warp deploy fuji<->arctestnet for MXNB.");
    }
}
