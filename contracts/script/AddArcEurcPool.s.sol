// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrivacyPool} from "privacy-pools/interfaces/IPrivacyPool.sol";

import {FxPrivacyPool} from "../src/hub/FxPrivacyPool.sol";

interface IEntrypointAdmin {
    function registerPool(
        IERC20 _asset,
        IPrivacyPool _pool,
        uint256 _minimumDepositAmount,
        uint256 _vettingFeeBPS,
        uint256 _maxRelayFeeBPS
    ) external;
}

/// @notice Add a shielded EURC pool to the live Arc Testnet privacy hook.
///
///         Reuses everything from `DeployPrivacyHookArc.s.sol`:
///           * existing FxPrivacyEntrypoint proxy at 0xd11cddd1…2736
///           * existing WithdrawalVerifier  0x7f0326ce…b6ee
///           * existing CommitmentVerifier  0x9056facd…8ea0
///         Only the new EURC `FxPrivacyPool` is constructed.
///
///         Pool config: asset=EURC, collateral=USDC. Morpho rehyp targets
///         Arc M1 (loan=EURC, collateral=USDC).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY  — must equal the entrypoint's OWNER_ROLE holder
///                           (registerPool is owner-only).
///
/// Optional env (Arc-sensible defaults):
///   ARC_USDC                 default 0x3600000000000000000000000000000000000000
///   ARC_EURC                 default 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
///   ARC_MORPHO               default 0x3c9b95C6E7B23f094f066733E7797C8680760830
///   ARC_REGISTRY             default 0x813232259c9b922e7571F15220617C80581f1464
///   ARC_PRIVACY_ENTRYPOINT   default 0xd11cddd1f04e850d3810a71608a49907c80f2736
///   ARC_PRIVACY_WV           default 0x7f0326cea0796e31ed38f01b1e8660faad7bb6ee
///   ARC_PRIVACY_CV           default 0x9056facd889a94e4acba8cbc4c8a81ed47ba8ea0
///   PRIV_MIN_EURC            default 1_000_000 (1 EURC, 6 dec)
///   PRIV_VETTING_FEE_BPS     default 0
///   PRIV_MAX_RELAY_FEE_BPS   default 500
contract AddArcEurcPool is Script {
    address constant DEFAULT_USDC       = 0x3600000000000000000000000000000000000000;
    address constant DEFAULT_EURC       = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant DEFAULT_MORPHO     = 0x3c9b95C6E7B23f094f066733E7797C8680760830;
    address constant DEFAULT_REGISTRY   = 0x813232259c9b922e7571F15220617C80581f1464;
    address constant DEFAULT_ENTRYPOINT = 0xD11cDdd1f04e850d3810a71608A49907c80f2736;
    address constant DEFAULT_WV         = 0x7f0326cea0796e31ED38F01B1E8660fAAd7BB6eE;
    address constant DEFAULT_CV         = 0x9056fAcd889a94E4aCBA8cbc4c8a81ED47Ba8EA0;

    function run() external {
        uint256 pk       = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc       = vm.envOr("ARC_USDC",               DEFAULT_USDC);
        address eurc       = vm.envOr("ARC_EURC",               DEFAULT_EURC);
        address morpho     = vm.envOr("ARC_MORPHO",             DEFAULT_MORPHO);
        address registry   = vm.envOr("ARC_REGISTRY",           DEFAULT_REGISTRY);
        address entrypoint = vm.envOr("ARC_PRIVACY_ENTRYPOINT", DEFAULT_ENTRYPOINT);
        address wv         = vm.envOr("ARC_PRIVACY_WV",         DEFAULT_WV);
        address cv         = vm.envOr("ARC_PRIVACY_CV",         DEFAULT_CV);

        uint256 minDeposit     = vm.envOr("PRIV_MIN_EURC",          uint256(1_000_000));
        uint256 vettingFeeBPS  = vm.envOr("PRIV_VETTING_FEE_BPS",   uint256(0));
        uint256 maxRelayFeeBPS = vm.envOr("PRIV_MAX_RELAY_FEE_BPS", uint256(500));

        require(usdc != address(0) && eurc != address(0), "asset zero");
        require(morpho != address(0) && registry != address(0), "infra zero");
        require(entrypoint != address(0), "entrypoint zero");
        require(wv != address(0) && cv != address(0), "verifier zero");

        console2.log("deployer            ", deployer);
        console2.log("Entrypoint          ", entrypoint);
        console2.log("WithdrawalVerifier  ", wv);
        console2.log("CommitmentVerifier  ", cv);
        console2.log("EURC (asset)        ", eurc);
        console2.log("USDC (collateral)   ", usdc);
        console2.log("MorphoBlue          ", morpho);
        console2.log("FxMarketRegistry    ", registry);

        vm.startBroadcast(pk);

        FxPrivacyPool eurcPool = new FxPrivacyPool(
            entrypoint,
            wv,
            cv,
            eurc,
            deployer,
            morpho,
            registry,
            usdc        // EURC pool collateral = USDC (Arc M1 pairs EURC<->USDC)
        );

        IEntrypointAdmin(entrypoint).registerPool(
            IERC20(eurc),
            IPrivacyPool(address(eurcPool)),
            minDeposit,
            vettingFeeBPS,
            maxRelayFeeBPS
        );

        vm.stopBroadcast();

        console2.log("=================================================");
        console2.log("Arc Testnet: EURC pool added");
        console2.log("=================================================");
        console2.log("FxPrivacyPool EURC ", address(eurcPool));
    }
}
