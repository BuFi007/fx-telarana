// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxPrivacyEntrypoint} from "../src/hub/FxPrivacyEntrypoint.sol";

/// @title ConfigurePrivacyDenominations
/// @notice Turns ON the authoritative on-chain fixed-denomination gate for
///         Ghost Mode on Arc Testnet.
///
///         WHY: a withdrawal amount is necessarily public on a transparent
///         chain (the pool calls token.transfer(recipient, withdrawnValue) and
///         the Groth16 circuit exposes withdrawnValue as a public signal). The
///         only amount-privacy lever is forcing every deposit/withdrawal to a
///         small shared set of amounts so they no longer uniquely link. This
///         needs NO new trusted setup — the deployed WithdrawalVerifier is
///         unchanged; the gate is a value-domain require() in the entrypoint.
///         See PRIVACY_CIRCUIT_WORKPLAN.md.
///
///         STEPS (single broadcast, deployer must hold _OWNER_ROLE):
///           1. deploy the new FxPrivacyEntrypoint impl (carries the
///              _beforeDeposit/_beforeWithdraw hooks + setDenominations)
///           2. UUPS-upgrade the live proxy to it
///           3. setDenominations() for each of the 6 shielded assets
///
///         The new impl adds ONLY appended storage + new functions; existing
///         slots are unchanged (ERC-7201 namespaced + appended struct fields),
///         so the upgrade is storage-safe.
///
///         Run (testnet only):
///           DEPLOYER_PRIVATE_KEY=0x... \
///           forge script script/ConfigurePrivacyDenominations.s.sol \
///             --rpc-url $ARC_RPC --broadcast
contract ConfigurePrivacyDenominations is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address constant DEFAULT_ENTRYPOINT = 0xD11cDdd1f04e850d3810a71608A49907c80f2736;

    // Shielded assets on Arc (mirror apps/hyper-mcp ghost.ts POOLS).
    address constant USDC   = 0x3600000000000000000000000000000000000000; // 6dp
    address constant EURC   = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a; // 6dp
    address constant MXNB   = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461; // 6dp
    address constant QCAD   = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d; // 6dp
    address constant AUDF   = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b; // 6dp
    address constant CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF; // 18dp

    error WrongChain(uint256 chainId);

    /// @dev Stablecoin denominations in atomic 6-decimal units: 1/10/100/1k/10k.
    function _stableDenoms() internal pure returns (uint256[] memory d) {
        d = new uint256[](5);
        d[0] = 1e6; d[1] = 10e6; d[2] = 100e6; d[3] = 1_000e6; d[4] = 10_000e6;
    }

    /// @dev cirBTC denominations in atomic 18-decimal units: 0.001/0.01/0.1/1.
    function _btcDenoms() internal pure returns (uint256[] memory d) {
        d = new uint256[](4);
        d[0] = 1e15; d[1] = 1e16; d[2] = 1e17; d[3] = 1e18;
    }

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address entrypoint = vm.envOr("ARC_PRIVACY_ENTRYPOINT", DEFAULT_ENTRYPOINT);

        console2.log("Configuring denomination gate on entrypoint:", entrypoint);

        vm.startBroadcast(pk);

        // 1 + 2: deploy new impl and upgrade the proxy to it.
        address newImpl = address(new FxPrivacyEntrypoint());
        FxPrivacyEntrypoint(payable(entrypoint)).upgradeToAndCall(newImpl, "");
        console2.log("upgraded impl ->", newImpl);

        // 3: register denomination sets (this also flips the gate ON per asset).
        FxPrivacyEntrypoint ep = FxPrivacyEntrypoint(payable(entrypoint));
        uint256[] memory stable = _stableDenoms();
        ep.setDenominations(IERC20(USDC), stable);
        ep.setDenominations(IERC20(EURC), stable);
        ep.setDenominations(IERC20(MXNB), stable);
        ep.setDenominations(IERC20(QCAD), stable);
        ep.setDenominations(IERC20(AUDF), stable);
        ep.setDenominations(IERC20(CIRBTC), _btcDenoms());

        vm.stopBroadcast();

        console2.log("denomination gate ENABLED for USDC/EURC/MXNB/QCAD/AUDF/cirBTC");
    }
}
