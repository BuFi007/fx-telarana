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

/// @notice Minimal interface for the post-init Entrypoint surface this
///         script invokes. Avoids importing the full upgradeable parent
///         twice through different inheritance chains.
interface IEntrypointAdmin {
    function registerPool(
        IERC20 _asset,
        IPrivacyPool _pool,
        uint256 _minimumDepositAmount,
        uint256 _vettingFeeBPS,
        uint256 _maxRelayFeeBPS
    ) external;
}

/// @notice Greenfield deploy of the fx-Telaraña Privacy Hook on Fuji.
///
///         v1 testnet scope (recommended Option A from the privacy-ship
///         plan): shielded USDC pool only. EURC pool deferred (M1/M2 on
///         live Fuji pair USDC with `MockEURC`, which is not user-acquirable
///         off-faucet — adds dApp friction for no real privacy gain). MXNB
///         pool deferred (the privacy branch lineage predates Stage 6's
///         MXNB markets — pick up in the next ship after merging main).
///
///         Cross-currency relay (FxPrivacyEntrypoint.relayCrossCurrency)
///         is NOT wired in this deploy. `setSwapAdapter` is left zero;
///         the call reverts `SwapAdapterNotSet` until ops wires it after
///         a concrete `IFxRouterSwapAdapter` ships against FxSwapHook.
///
///         Prerequisite: PoseidonT3 + PoseidonT4 must be deployed at PSE's
///         canonical deterministic addresses before running this script —
///         FxPrivacyPool's compiled bytecode links to those addresses via
///         the `libraries = [...]` block in `foundry.toml`. If they aren't
///         present, run `DeployPoseidonFuji.s.sol` first (one-shot, idempotent).
///
/// Deploy sequence:
///   1. WithdrawalVerifier  (vendored 0xbow Groth16 contract)
///   2. CommitmentVerifier  (vendored — used as the ragequit verifier)
///   3. FxPrivacyEntrypoint implementation
///   4. ERC1967Proxy(impl, initData=initialize(deployer, postman))
///   5. FxPrivacyPool(asset=USDC, collateral=MockEURC, owner=deployer,
///                    morpho=live, registry=live)
///   6. entrypoint.registerPool(USDC, pool, min, vettingFee, maxRelay)
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY      — must be funded with Fuji AVAX.
///
/// Optional env (Fuji-sensible defaults):
///   FUJI_USDC                 default 0x5425890298aed601595a70AB815c96711a31Bc65
///   FUJI_MOCK_EURC            default 0x50c4ba39caa7f56152d0df4914e1f6b907194992
///                             (live Fuji M1/M2 use this as the EURC leg)
///   FUJI_MORPHO               default 0xeF64621D41093144D9ED8aB8327eE381ECdB79E6
///   FUJI_REGISTRY             default 0x7ba745b979e027992ECFa51207666e3F5B46cF0a
///   PRIV_POSTMAN              default deployer
///                             ASP-postman role. Rotate to the relayer EOA
///                             after deploy via entrypoint.grantRole.
///   PRIV_MIN_USDC             default 1_000_000 (1 USDC, 6 dec)
///   PRIV_VETTING_FEE_BPS      default 0 (testnet — no fee)
///   PRIV_MAX_RELAY_FEE_BPS    default 500 (5% cap; per-call fee chosen by user)
contract DeployPrivacyHookFuji is Script {
    /*//////////////////////////////////////////////////////////////
                                DEFAULTS
    //////////////////////////////////////////////////////////////*/

    address constant DEFAULT_USDC      = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address constant DEFAULT_MOCK_EURC = 0x50C4BA39CAA7f56152d0df4914e1F6b907194992;
    address constant DEFAULT_MORPHO    = 0xeF64621D41093144D9ED8aB8327eE381ECdB79E6;
    address constant DEFAULT_REGISTRY  = 0x7ba745b979e027992ECFa51207666e3F5B46cF0a;

    /*//////////////////////////////////////////////////////////////
                                RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        uint256 pk       = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc     = vm.envOr("FUJI_USDC",      DEFAULT_USDC);
        address eurc     = vm.envOr("FUJI_MOCK_EURC", DEFAULT_MOCK_EURC);
        address morpho   = vm.envOr("FUJI_MORPHO",    DEFAULT_MORPHO);
        address registry = vm.envOr("FUJI_REGISTRY",  DEFAULT_REGISTRY);
        address postman  = vm.envOr("PRIV_POSTMAN",   deployer);

        uint256 minDeposit    = vm.envOr("PRIV_MIN_USDC",            uint256(1_000_000));
        uint256 vettingFeeBPS = vm.envOr("PRIV_VETTING_FEE_BPS",     uint256(0));
        uint256 maxRelayFeeBPS = vm.envOr("PRIV_MAX_RELAY_FEE_BPS",  uint256(500));

        require(usdc      != address(0), "USDC zero");
        require(eurc      != address(0), "EURC zero");
        require(morpho    != address(0), "Morpho zero");
        require(registry  != address(0), "Registry zero");
        require(postman   != address(0), "Postman zero");

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

        // 1. Real Groth16 verifiers (vendored 0xbow).
        WithdrawalVerifier withdrawalVerifier = new WithdrawalVerifier();
        CommitmentVerifier commitmentVerifier = new CommitmentVerifier();

        // 2. UUPS Entrypoint behind ERC1967Proxy. Implementation disables
        //    its own initializer in ctor; we initialize through the proxy.
        FxPrivacyEntrypoint entrypointImpl = new FxPrivacyEntrypoint();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)",
            deployer,
            postman
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(entrypointImpl), initData);
        FxPrivacyEntrypoint entrypoint = FxPrivacyEntrypoint(payable(address(proxy)));

        // 3. USDC pool. Collateral = MockEURC (live M1/M2 paired leg);
        //    rehyp targets Morpho M2 (USDC=loan, MockEURC=collateral)
        //    when hot reserve runs short.
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

        // 4. Register the pool with the entrypoint. Owner-gated; deployer
        //    holds the owner role from step 2's initialize.
        IEntrypointAdmin(address(entrypoint)).registerPool(
            IERC20(usdc),
            IPrivacyPool(address(usdcPool)),
            minDeposit,
            vettingFeeBPS,
            maxRelayFeeBPS
        );

        vm.stopBroadcast();

        console2.log("=================================================");
        console2.log("fx-Telarana Privacy Hook (Fuji)");
        console2.log("=================================================");
        console2.log("WithdrawalVerifier        ", address(withdrawalVerifier));
        console2.log("CommitmentVerifier        ", address(commitmentVerifier));
        console2.log("FxPrivacyEntrypoint impl  ", address(entrypointImpl));
        console2.log("FxPrivacyEntrypoint proxy ", address(entrypoint));
        console2.log("FxPrivacyPool USDC        ", address(usdcPool));
        console2.log("");
        console2.log("Next: ASP postman is currently the deployer. Once");
        console2.log("the relayer service has a stable EOA, run:");
        console2.log("  entrypoint.grantRole(ASP_POSTMAN, <relayerEOA>)");
        console2.log("  entrypoint.revokeRole(ASP_POSTMAN, deployer)");
    }
}
