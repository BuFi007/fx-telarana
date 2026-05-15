// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICircleGatewayMinter} from "../src/interfaces/ICircleGateway.sol";
import {ITelaranaGatewayHubHook} from "../src/interfaces/ITelaranaGatewayHubHook.sol";
import {TelaranaGatewayHubHook} from "../src/hub/TelaranaGatewayHubHook.sol";
import {MockStablecoin} from "../src/test-helpers/MockStablecoin.sol";

/// @dev MockMinter mirrors `test/TelaranaGatewayHubHook.t.sol`'s pattern —
///      Circle's real Gateway Minter isn't deployed on the Fuji vnet, so the
///      smoke script ships its own. `gatewayMint` mints into the configured
///      recipient with the configured amount (set by the smoke script before
///      each `receiveGatewayMint` call).
contract SmokeMockCircleGatewayMinter is ICircleGatewayMinter {
    MockStablecoin public immutable usdc;
    address public mintRecipient;
    uint256 public mintAmount;
    bytes32 public lastPayloadHash;
    bytes32 public lastSignatureHash;

    constructor(address usdc_) {
        usdc = MockStablecoin(usdc_);
    }

    function setMint(address recipient, uint256 amount) external {
        mintRecipient = recipient;
        mintAmount = amount;
    }

    function gatewayMint(bytes calldata attestationPayload, bytes calldata signature) external {
        lastPayloadHash = keccak256(attestationPayload);
        lastSignatureHash = keccak256(signature);
        usdc.mint(mintRecipient, mintAmount);
    }
}

/// @notice Tenderly Fuji-only smoke for the Telaraña Avalanche→Arc gateway-hub
///         path. Telaraña's "Spider Web" composes spokes + hub + hub-to-hub
///         Circle-Gateway USDC liquidity. This smoke proves the destination-hub
///         leg: a synthetic Circle Gateway attestation lands on the destination
///         hub's `TelaranaGatewayHubHook`, USDC mints, balance delta matches,
///         the request is idempotent, and a disabled route blocks new mints.
///
/// Reads the basket manifest written by `Phase1_Core` for USDC + executor
/// addresses. Persists `TelaranaGatewayHubHook` + `SmokeMockCircleGatewayMinter`
/// addresses to a dedicated sub-manifest at
/// `deployments/_tenderly-basket-phases/smoke-gateway-avax-to-arc.json` so the
/// driver script can merge it into the canonical basket manifest.
///
/// Constraints:
///   * Testnet only. Reverts on non-Fuji chain id.
///   * Mock minter is used because Circle's real Gateway Minter isn't on Fuji.
///   * Gateway is USDC-only per the Telaraña config (see handoff prompt §73).
contract SmokeTenderlyGatewayAvaxToArc is Script {
    uint32 internal constant AVAX_DOMAIN = 1;   // CCTP V2 domain for Avalanche
    uint32 internal constant ARC_DOMAIN = 26;   // CCTP V2 domain for Arc testnet
    bytes32 internal constant ROUTE_ID = keccak256("telarana-gateway-fuji-to-arc-usdc");
    bytes32 internal constant METADATA_REF = keccak256("telarana-gateway-fuji-arc-v0");

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        require(
            block.chainid == 43113 || block.chainid == 5042002,
            "Smoke: testnet-only (Fuji 43113 or Arc 5042002)"
        );

        string memory manifestPath =
            vm.envOr("FXT_BASKET_MANIFEST", string("./deployments/tenderly-avalanche-fuji-basket.json"));
        string memory raw = vm.readFile(manifestPath);
        address usdcAddr = vm.parseJsonAddress(raw, ".USDC");
        address destinationHub = vm.parseJsonAddress(raw, ".FxHubMessageReceiver");

        require(usdcAddr != address(0), "Smoke: USDC missing from manifest");
        require(destinationHub != address(0), "Smoke: FxHubMessageReceiver missing from manifest");

        // Optional override: route the gateway mint to a custom destination hub
        // (e.g. an Arc-side mirror address). Defaults to FxHubMessageReceiver
        // which already implements the destination-hub interface.
        address destinationHubOverride = vm.envOr("FXT_GATEWAY_DESTINATION_HUB", address(0));
        if (destinationHubOverride != address(0)) {
            destinationHub = destinationHubOverride;
        }

        // Executors come from the manifest if present; default to deployer.
        address executor = vm.envOr("FXT_GATEWAY_EXECUTOR", deployer);
        address sourceDepositor = vm.envOr("FXT_GATEWAY_SOURCE_DEPOSITOR", address(0xD3F0517));
        address sourceSigner = vm.envOr("FXT_GATEWAY_SOURCE_SIGNER", address(0x519E7));
        address sourceUsdc = vm.envOr("FXT_GATEWAY_SOURCE_USDC", address(0xF1F1));
        address sourceGatewayWallet = vm.envOr("FXT_GATEWAY_SOURCE_WALLET", address(0x7777));
        address mintRecipient = vm.envOr("FXT_GATEWAY_RECIPIENT", address(0xB0B));

        bytes32 requestIdA = keccak256(abi.encodePacked("smoke-request-", block.timestamp, "-A"));
        bytes32 requestIdB = keccak256(abi.encodePacked("smoke-request-", block.timestamp, "-B"));

        vm.startBroadcast(pk);

        SmokeMockCircleGatewayMinter minter = new SmokeMockCircleGatewayMinter(usdcAddr);
        TelaranaGatewayHubHook hook = new TelaranaGatewayHubHook(usdcAddr, address(minter), deployer);

        // Wire the route: AVAX (domain 1) → Arc (domain 26).
        hook.grantRole(hook.EXECUTOR_ROLE(), executor);
        ITelaranaGatewayHubHook.GatewayHubRoute memory route = ITelaranaGatewayHubHook.GatewayHubRoute({
            sourceDomain: AVAX_DOMAIN,
            destinationDomain: ARC_DOMAIN,
            sourceUsdc: sourceUsdc,
            destinationUsdc: usdcAddr,
            sourceGatewayWallet: sourceGatewayWallet,
            destinationGatewayMinter: address(minter),
            destinationHub: destinationHub,
            whitelistedCaller: executor,
            signerMode: ITelaranaGatewayHubHook.GatewaySignerMode.EOA,
            enabled: true,
            metadataRef: METADATA_REF
        });
        hook.setGatewayRoute(ROUTE_ID, route);

        // --- Probe A: happy path. Synthetic attestation lands; USDC mints; balance
        //               forwarded to destination hub.
        uint256 amountA = 100e6;
        minter.setMint(address(hook), amountA);
        uint256 destBalBefore = IERC20(usdcAddr).balanceOf(destinationHub);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctxA = ITelaranaGatewayHubHook.GatewayMintContext({
            routeId: ROUTE_ID,
            requestId: requestIdA,
            action: ITelaranaGatewayHubHook.GatewayHubAction.MINT_TO_HUB,
            sourceDepositor: sourceDepositor,
            sourceSigner: sourceSigner,
            recipient: mintRecipient,
            tokenOut: address(0),
            amount: amountA,
            minAmountOut: 0,
            spotRouteId: bytes32(0),
            metadataRef: keccak256("smoke-metadata-A"),
            hookData: ""
        });

        // Executor in test is the deployer by default; if env'd to a different
        // address, this broadcast would fail. We use the deployer as executor
        // for the smoke run since we control the privkey.
        require(executor == deployer, "Smoke: executor must be deployer for this broadcast");
        uint256 amountReceivedA = hook.receiveGatewayMint("smoke-attestation-A", "smoke-signature-A", ctxA);

        require(amountReceivedA == amountA, "Smoke: amount delta mismatch");
        require(IERC20(usdcAddr).balanceOf(address(hook)) == 0, "Smoke: hook held leftover USDC");
        require(
            IERC20(usdcAddr).balanceOf(destinationHub) == destBalBefore + amountA,
            "Smoke: destination hub did not receive forwarded USDC"
        );
        require(
            uint8(hook.gatewayRequestState(requestIdA))
                == uint8(ITelaranaGatewayHubHook.GatewayRequestState.MINTED),
            "Smoke: requestId not marked MINTED"
        );

        // --- Probe B: idempotency. Re-using requestIdA must revert with
        //               DuplicateRequest. We catch the revert in-broadcast via
        //               try-catch on the hook external call.
        bool gotDuplicateRevert;
        try hook.receiveGatewayMint("smoke-attestation-A2", "smoke-signature-A2", ctxA) {
            gotDuplicateRevert = false;
        } catch {
            gotDuplicateRevert = true;
        }
        require(gotDuplicateRevert, "Smoke: duplicate requestId did not revert");

        // --- Probe C: route disabled blocks new mints.
        route.enabled = false;
        hook.setGatewayRoute(ROUTE_ID, route);

        ITelaranaGatewayHubHook.GatewayMintContext memory ctxB = ctxA;
        ctxB.requestId = requestIdB;
        minter.setMint(address(hook), amountA);
        bool gotDisabledRevert;
        try hook.receiveGatewayMint("smoke-attestation-B", "smoke-signature-B", ctxB) {
            gotDisabledRevert = false;
        } catch {
            gotDisabledRevert = true;
        }
        require(gotDisabledRevert, "Smoke: disabled route did not revert");

        // Restore route to enabled for downstream tests.
        route.enabled = true;
        hook.setGatewayRoute(ROUTE_ID, route);

        vm.stopBroadcast();

        // Sub-manifest write — merged into the canonical basket manifest by the driver.
        string memory root = "smoke-gateway-avax-to-arc";
        vm.serializeAddress(root, "TelaranaGatewayHubHook", address(hook));
        vm.serializeAddress(root, "SmokeMockCircleGatewayMinter", address(minter));
        vm.serializeAddress(root, "smoke_gateway_destinationHub", destinationHub);
        vm.serializeAddress(root, "smoke_gateway_executor", executor);
        vm.serializeAddress(root, "smoke_gateway_recipient", mintRecipient);
        vm.serializeUint(root, "smoke_gateway_sourceDomain", AVAX_DOMAIN);
        vm.serializeUint(root, "smoke_gateway_destinationDomain", ARC_DOMAIN);
        vm.serializeBytes32(root, "smoke_gateway_routeId", ROUTE_ID);
        vm.serializeBytes32(root, "smoke_gateway_metadataRef", METADATA_REF);
        vm.serializeBytes32(root, "smoke_gateway_requestId_A", requestIdA);
        vm.serializeBytes32(root, "smoke_gateway_requestId_B", requestIdB);
        vm.serializeUint(root, "smoke_gateway_amountA", amountA);
        string memory json = vm.serializeString(
            root,
            "smoke_gateway_notes",
            "Smoke proves destination-hub mint+forward+idempotency+disabled-route. Mock minter; not Circle's real Gateway Minter."
        );

        string memory subManifestPath = string.concat(
            vm.envOr("FXT_BASKET_PHASES_DIR", string("./deployments/_tenderly-basket-phases")),
            "/smoke-gateway-avax-to-arc.json"
        );
        vm.writeJson(json, subManifestPath);

        console2.log("Gateway smoke OK. Hook", address(hook));
        console2.log("Mock minter", address(minter));
        console2.log("Destination hub", destinationHub);
        console2.log("Amount forwarded", amountA);
    }
}
