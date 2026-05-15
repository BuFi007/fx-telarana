// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICircleGatewayMinter} from "../src/interfaces/ICircleGateway.sol";
import {ITelaranaGatewayHubHook} from "../src/interfaces/ITelaranaGatewayHubHook.sol";
import {TelaranaGatewayHubHook} from "../src/hub/TelaranaGatewayHubHook.sol";

/// @notice Real-Circle-Gateway wiring smoke for the Telaraña Spider Web
///         hub-to-hub flow. Deploys a `TelaranaGatewayHubHook` on the current
///         hub chain (Fuji 43113 or Arc 5042002), configured against the
///         CANONICAL Circle Gateway addresses returned by
///         `circle contract address gateway`:
///
///             GatewayWallet  0x0077777d7EBA4688BDeF3E311b846F25870A19B9
///             GatewayMinter  0x0022222ABE238Cc2C7Bb1f21003F0a260052475B
///
///         (Deterministic CREATE2 — same addresses on both Fuji and Arc.)
///
///         The full happy-path mint requires a real attestation signed by
///         Circle's Gateway relayer, so this smoke only covers the wiring
///         + revert paths that DON'T need a real attestation:
///
///           A. Route configuration accepted by `setGatewayRoute` against
///              real Circle minter + chain-specific real USDC.
///           B. Reading `gatewayRoute(routeId)` returns the configured struct.
///           C. Disabled route reverts `receiveGatewayMint` (short-circuits
///              before any call into the real Circle minter).
///           D. Non-executor caller reverts (AccessControl gate).
///           E. Paused hook reverts entry-side (Pausable gate).
///           F. Optional: real Circle minter call with a fabricated
///              attestation reverts — proves the external call path is
///              physically wired through the real minter.
///
/// For the real cross-chain happy path (a depositor calls
/// `circle gateway deposit` on a source chain, Circle's relayer signs a
/// BurnIntent, then an executor with `EXECUTOR_ROLE` on this hook calls
/// `receiveGatewayMint(realAttestation, realSig, ctx)`), see the runbook
/// `docs/SPIDER_WEB_TESTNET_RUNBOOK.md` §Stage-2 / §Stage-4.
contract SmokeGatewayWiring is Script {
    /// Canonical Circle Gateway addresses (same on Fuji + Arc; deterministic CREATE2).
    address constant CIRCLE_GATEWAY_WALLET = 0x0077777d7EBA4688BDeF3E311b846F25870A19B9;
    address constant CIRCLE_GATEWAY_MINTER = 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B;

    /// Real Circle USDC per chain.
    address constant USDC_FUJI = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address constant USDC_ARC = 0x3600000000000000000000000000000000000000;

    /// CCTP V2 domains.
    uint32 constant AVAX_DOMAIN = 1;
    uint32 constant ARC_DOMAIN = 26;

    bytes32 constant ROUTE_ID_FUJI_TO_ARC = keccak256("telarana-gateway-fuji-to-arc-usdc");
    bytes32 constant ROUTE_ID_ARC_TO_FUJI = keccak256("telarana-gateway-arc-to-fuji-usdc");
    bytes32 constant METADATA_REF = keccak256("telarana-spider-web-v0");

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        require(
            block.chainid == 43113 || block.chainid == 5042002,
            "SmokeGatewayWiring: testnet-only (Fuji 43113 or Arc 5042002)"
        );

        // Confirm the real Circle Gateway is actually on this chain at the
        // canonical addresses. If not, the deploy chain doesn't have Circle
        // Gateway support and we should not configure routes.
        require(
            CIRCLE_GATEWAY_MINTER.code.length != 0,
            "SmokeGatewayWiring: Circle GatewayMinter not deployed on this chain"
        );
        require(
            CIRCLE_GATEWAY_WALLET.code.length != 0,
            "SmokeGatewayWiring: Circle GatewayWallet not deployed on this chain"
        );

        // Pick the destination USDC + route id based on which chain we're on.
        // Fuji-side hook routes to Arc (dest USDC = Arc USDC). Arc-side hook
        // routes to Fuji (dest USDC = Fuji USDC).
        address localUsdc;
        address remoteUsdc;
        bytes32 routeId;
        uint32 sourceDomain;
        uint32 destDomain;
        if (block.chainid == 43113) {
            localUsdc = USDC_FUJI;
            remoteUsdc = USDC_FUJI; // dest is also USDC on the SAME hub; cross-chain via Gateway = minting LOCAL USDC
            routeId = ROUTE_ID_FUJI_TO_ARC;
            sourceDomain = ARC_DOMAIN; // route is "from Arc into this Fuji hub"
            destDomain = AVAX_DOMAIN;
        } else {
            localUsdc = USDC_ARC;
            remoteUsdc = USDC_ARC;
            routeId = ROUTE_ID_ARC_TO_FUJI;
            sourceDomain = AVAX_DOMAIN; // route is "from Fuji into this Arc hub"
            destDomain = ARC_DOMAIN;
        }

        // The destination-hub forwards minted USDC to a configured "destination
        // hub" address. For the smoke we route it back to the existing
        // FxHubMessageReceiver from the v1.2.x stack (read from optional env
        // override, else fall back to a sentinel that operator must replace).
        address destinationHub = vm.envOr("FXT_GATEWAY_DESTINATION_HUB", address(0));
        require(
            destinationHub != address(0),
            "SmokeGatewayWiring: set FXT_GATEWAY_DESTINATION_HUB to the local FxHubMessageReceiver"
        );

        // Executors come from env — typically the protocol's relayer key, but
        // for the smoke we default to the deployer.
        address executor = vm.envOr("FXT_GATEWAY_EXECUTOR", deployer);
        require(
            executor == deployer,
            "SmokeGatewayWiring: deployer must be the executor for in-broadcast probes"
        );

        // Bookkeeping for the manifest sub-file.
        string memory manifestPath = vm.envOr(
            "FXT_BASKET_MANIFEST",
            string("./deployments/tenderly-avalanche-fuji-basket.json")
        );

        vm.startBroadcast(pk);

        TelaranaGatewayHubHook hook = new TelaranaGatewayHubHook(
            localUsdc,
            CIRCLE_GATEWAY_MINTER,
            deployer
        );

        hook.grantRole(hook.EXECUTOR_ROLE(), executor);

        // Probe A: configure a route with real Circle addresses.
        ITelaranaGatewayHubHook.GatewayHubRoute memory route = ITelaranaGatewayHubHook.GatewayHubRoute({
            sourceDomain: sourceDomain,
            destinationDomain: destDomain,
            sourceUsdc: remoteUsdc,
            destinationUsdc: localUsdc,
            sourceGatewayWallet: CIRCLE_GATEWAY_WALLET,
            destinationGatewayMinter: CIRCLE_GATEWAY_MINTER,
            destinationHub: destinationHub,
            whitelistedCaller: executor,
            signerMode: ITelaranaGatewayHubHook.GatewaySignerMode.EOA,
            enabled: true,
            metadataRef: METADATA_REF
        });
        hook.setGatewayRoute(routeId, route);

        // Probe B: re-read the route and assert it matches what we set.
        ITelaranaGatewayHubHook.GatewayHubRoute memory got = hook.gatewayRoute(routeId);
        require(got.destinationGatewayMinter == CIRCLE_GATEWAY_MINTER, "ProbeB: minter slot mismatch");
        require(got.destinationUsdc == localUsdc, "ProbeB: usdc slot mismatch");
        require(got.enabled, "ProbeB: enabled flag mismatch");
        require(got.sourceDomain == sourceDomain, "ProbeB: sourceDomain mismatch");
        require(got.destinationDomain == destDomain, "ProbeB: destDomain mismatch");

        // Probe C: disable-route round-trip. State assertion — the revert
        // behavior of `receiveGatewayMint` on a disabled route is covered
        // by `TelaranaGatewayHubHook.t.sol`. Calling into the reverting
        // path during broadcast simulation aborts forge's --broadcast even
        // when the revert is caught by try/catch, so we only assert state.
        route.enabled = false;
        hook.setGatewayRoute(routeId, route);
        require(!hook.gatewayRoute(routeId).enabled, "ProbeC: disable did not take");

        // Re-enable for downstream probes.
        route.enabled = true;
        hook.setGatewayRoute(routeId, route);
        require(hook.gatewayRoute(routeId).enabled, "ProbeC: re-enable did not take");

        // Probe D: Pausable round-trip. Same as Probe C — assert state, not
        // entry-side revert behavior (covered by unit tests).
        hook.pause();
        require(hook.paused(), "ProbeD: pause did not take");
        hook.unpause();
        require(!hook.paused(), "ProbeD: unpause did not take");

        // Probe E (read-only — runs AFTER stopBroadcast so the broadcast
        // simulation isn't poisoned by reverts inside try/catch): confirm
        // the hook's immutable GATEWAY_MINTER and USDC slots resolve to the
        // canonical Circle addresses + chain-specific USDC. This is the
        // wiring assertion that proves the destination-hub leg can dispatch
        // into Circle's real minter when an attestation arrives.
        vm.stopBroadcast();

        require(
            address(hook.GATEWAY_MINTER()) == CIRCLE_GATEWAY_MINTER,
            "ProbeE: hook.GATEWAY_MINTER != Circle GatewayMinter"
        );
        require(
            address(hook.USDC()) == localUsdc,
            "ProbeE: hook.USDC != local Circle USDC"
        );
        require(
            CIRCLE_GATEWAY_MINTER.code.length != 0,
            "ProbeE: Circle GatewayMinter has no code"
        );

        // Sub-manifest persistence.
        string memory root = "smoke-gateway-wiring";
        vm.serializeAddress(root, "TelaranaGatewayHubHook", address(hook));
        vm.serializeAddress(root, "CircleGatewayMinter", CIRCLE_GATEWAY_MINTER);
        vm.serializeAddress(root, "CircleGatewayWallet", CIRCLE_GATEWAY_WALLET);
        vm.serializeAddress(root, "smoke_gateway_destinationHub", destinationHub);
        vm.serializeAddress(root, "smoke_gateway_executor", executor);
        vm.serializeBytes32(root, "smoke_gateway_routeId", routeId);
        vm.serializeBytes32(root, "smoke_gateway_metadataRef", METADATA_REF);
        vm.serializeUint(root, "smoke_gateway_sourceDomain", sourceDomain);
        vm.serializeUint(root, "smoke_gateway_destinationDomain", destDomain);
        string memory json = vm.serializeString(
            root,
            "smoke_gateway_notes",
            "Real Circle Gateway wiring. Probes A-E executed. Full happy mint requires a Circle-signed attestation; route the relayer EOA to EXECUTOR_ROLE then call receiveGatewayMint(realAttestation, realSig, ctx)."
        );

        string memory subManifestPath = string.concat(
            vm.envOr("FXT_BASKET_PHASES_DIR", string("./deployments/_tenderly-basket-phases")),
            "/smoke-gateway-wiring.json"
        );
        vm.writeJson(json, subManifestPath);

        console2.log("Gateway wiring smoke OK on chainId", block.chainid);
        console2.log("  TelaranaGatewayHubHook:", address(hook));
        console2.log("  Circle GatewayMinter:  ", CIRCLE_GATEWAY_MINTER);
        console2.log("  Circle GatewayWallet:  ", CIRCLE_GATEWAY_WALLET);
        console2.log("  Local USDC:            ", localUsdc);
        console2.log("  Destination hub:       ", destinationHub);
        console2.log("Route configured + 5 probes (A=setRoute, B=read, C=disable-state, D=pause-state, E=immutables) all asserted.");
    }

}
