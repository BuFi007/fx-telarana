// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WithdrawalVerifier} from "privacy-pools/contracts/verifiers/WithdrawalVerifier.sol";
import {CommitmentVerifier} from "privacy-pools/contracts/verifiers/CommitmentVerifier.sol";
import {IPrivacyPool} from "privacy-pools/interfaces/IPrivacyPool.sol";

import {FxPrivacyEntrypoint} from "../src/hub/FxPrivacyEntrypoint.sol";
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

/// @notice Greenfield deploy of the fx-Telaraña Privacy Hook on Arc Testnet.
///
///         Mirrors DeployPrivacyHookFuji.s.sol — same v1 scope:
///         shielded USDC pool only, no cross-currency relay wired.
///
///         Arc-specific differences vs Fuji:
///           * USDC is the 6-dec ERC-20 wrapper at the special 0x3600... address
///             (native AVAX gas is 18-dec; the ERC-20 here is what CCTP V2 and
///             FxMarketRegistry pair against).
///           * Collateral leg is REAL Circle-deployed EURC (0x89B5...), not the
///             MockEURC kludge Fuji uses. Arc M1 pairs USDC<->EURC directly.
///           * Self-deployed MorphoBlue at 0x3c9b... (Arc has no canonical
///             Morpho deploy yet, so the project shipped its own).
///
///         Prerequisite: PoseidonT3 + PoseidonT4 must be deployed at PSE's
///         canonical addresses on Arc before running this script. Run
///         `FOUNDRY_PROFILE=deploy forge script script/DeployPoseidon.s.sol
///         --rpc-url $ARC_RPC --broadcast` first (idempotent).
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY      — must be funded on Arc (USDC for gas).
///
/// Optional env (Arc-sensible defaults):
///   ARC_USDC                  default 0x3600000000000000000000000000000000000000
///   ARC_EURC                  default 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
///   ARC_MORPHO                default 0x3c9b95C6E7B23f094f066733E7797C8680760830
///   ARC_REGISTRY              default 0x813232259c9b922e7571F15220617C80581f1464
///   PRIV_POSTMAN              default deployer
///   PRIV_MIN_USDC             default 1_000_000 (1 USDC, 6 dec)
///   PRIV_VETTING_FEE_BPS      default 0
///   PRIV_MAX_RELAY_FEE_BPS    default 500
contract DeployPrivacyHookArc is Script {
    address constant DEFAULT_USDC     = 0x3600000000000000000000000000000000000000;
    address constant DEFAULT_EURC     = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant DEFAULT_MORPHO   = 0x3c9b95C6E7B23f094f066733E7797C8680760830;
    address constant DEFAULT_REGISTRY = 0x813232259c9b922e7571F15220617C80581f1464;

    function run() external {
        uint256 pk       = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc     = vm.envOr("ARC_USDC",     DEFAULT_USDC);
        address eurc     = vm.envOr("ARC_EURC",     DEFAULT_EURC);
        address morpho   = vm.envOr("ARC_MORPHO",   DEFAULT_MORPHO);
        address registry = vm.envOr("ARC_REGISTRY", DEFAULT_REGISTRY);
        address postman  = vm.envOr("PRIV_POSTMAN", deployer);

        uint256 minDeposit     = vm.envOr("PRIV_MIN_USDC",          uint256(1_000_000));
        uint256 vettingFeeBPS  = vm.envOr("PRIV_VETTING_FEE_BPS",   uint256(0));
        uint256 maxRelayFeeBPS = vm.envOr("PRIV_MAX_RELAY_FEE_BPS", uint256(500));

        require(usdc     != address(0), "USDC zero");
        require(eurc     != address(0), "EURC zero");
        require(morpho   != address(0), "Morpho zero");
        require(registry != address(0), "Registry zero");
        require(postman  != address(0), "Postman zero");

        console2.log("deployer         ", deployer);
        console2.log("postman          ", postman);
        console2.log("USDC             ", usdc);
        console2.log("EURC (collateral)", eurc);
        console2.log("MorphoBlue       ", morpho);
        console2.log("FxMarketRegistry ", registry);
        console2.log("minDeposit       ", minDeposit);
        console2.log("vettingFeeBPS    ", vettingFeeBPS);
        console2.log("maxRelayFeeBPS   ", maxRelayFeeBPS);

        vm.startBroadcast(pk);

        WithdrawalVerifier withdrawalVerifier = new WithdrawalVerifier();
        CommitmentVerifier commitmentVerifier = new CommitmentVerifier();

        FxPrivacyEntrypoint entrypointImpl = new FxPrivacyEntrypoint();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)",
            deployer,
            postman
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(entrypointImpl), initData);
        FxPrivacyEntrypoint entrypoint = FxPrivacyEntrypoint(payable(address(proxy)));

        FxPrivacyPool usdcPool = new FxPrivacyPool(
            address(entrypoint),
            address(withdrawalVerifier),
            address(commitmentVerifier),
            usdc,
            deployer,
            morpho,
            registry,
            eurc
        );

        IEntrypointAdmin(address(entrypoint)).registerPool(
            IERC20(usdc),
            IPrivacyPool(address(usdcPool)),
            minDeposit,
            vettingFeeBPS,
            maxRelayFeeBPS
        );

        vm.stopBroadcast();

        console2.log("=================================================");
        console2.log("fx-Telarana Privacy Hook (Arc Testnet)");
        console2.log("=================================================");
        console2.log("WithdrawalVerifier        ", address(withdrawalVerifier));
        console2.log("CommitmentVerifier        ", address(commitmentVerifier));
        console2.log("FxPrivacyEntrypoint impl  ", address(entrypointImpl));
        console2.log("FxPrivacyEntrypoint proxy ", address(entrypoint));
        console2.log("FxPrivacyPool USDC        ", address(usdcPool));
    }
}
