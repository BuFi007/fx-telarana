// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxReserveYieldRouter} from "../src/vault/FxReserveYieldRouter.sol";
import {IUsycTeller} from "../src/vault/interfaces/IUsycTeller.sol";

/// @notice Deploys the P1 FxReserveYieldRouter (USYC sink, tier-gated) behind a UUPS proxy on Arc
///         Testnet. The Yield Machine, phase 1 — see docs/architecture/yield-machine-spec.md (BUFX).
///
/// @dev    AFTER deploy you MUST submit the PROXY ADDRESS to Circle/Hashnote for entitlement in the
///         USYC Entitlements contract 0xcc205224862c7641930c87679e98999d23c26113 (same flow already
///         done for keeper 0xcA02). Until the proxy is entitled, `deposit`/`redeem` on the Teller
///         revert on the on-chain authority check. View calls + funding the buffer work regardless.
///
///         Run:
///           forge script script/DeployReserveYieldRouter.s.sol \
///             --rpc-url https://rpc.testnet.arc.network \
///             --private-key $DEPLOYER_PRIVATE_KEY --broadcast
///
///         P2 (Morpho sinks) is wired post-deploy via GOVERNANCE (markets carry per-market
///         oracle/irm/lltv from the morpho deploy manifests, so they're not baked in here):
///           router.setMorpho(0x3c9b95C6E7B23f094f066733E7797C8680760830)          // Arc Morpho
///           router.setUsdcMorphoMarket(usdcLoanMarket, true, targetBps)            // USDC base yield
///           router.addFxMarket(EURC, eurcLoanMarket, low, high)                    // FX inventory yield
///         (Arc Morpho USDC/EURC market is a ghost market today — 0% util — so leave Morpho
///         disabled until a market has real borrow demand; USYC carries the yield meanwhile.)
contract DeployReserveYieldRouter is Script {
    // --- Verified live Arc Testnet addresses (2026-06) ---
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000; // native USDC (Teller.asset())
    address constant ARC_USYC = 0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C; // 6 dec
    address constant ARC_USYC_TELLER = 0x9fdF14c5B14173D74C08Af27AebFf39240dC105A;

    function run() external {
        // Admin + timelock: default to the deployer; override via env for production wiring.
        address deployer = msg.sender;
        address admin = vm.envOr("ROUTER_ADMIN", deployer);
        address timelock = vm.envOr("ROUTER_TIMELOCK", deployer);
        // (s,S) watermarks in USDC (6 dec). Conservative defaults; tune via setWaterMarks.
        uint256 lowWater = vm.envOr("ROUTER_LOW_WATER", uint256(5_000e6));
        uint256 highWater = vm.envOr("ROUTER_HIGH_WATER", uint256(20_000e6));

        vm.startBroadcast();

        FxReserveYieldRouter impl = new FxReserveYieldRouter();
        bytes memory initData = abi.encodeCall(
            FxReserveYieldRouter.initialize,
            (
                IERC20(ARC_USDC),
                IERC20(ARC_USYC),
                IUsycTeller(ARC_USYC_TELLER),
                admin,
                timelock,
                lowWater,
                highWater
            )
        );
        FxReserveYieldRouter router = FxReserveYieldRouter(address(new ERC1967Proxy(address(impl), initData)));

        vm.stopBroadcast();

        console2.log("FxReserveYieldRouter impl :", address(impl));
        console2.log("FxReserveYieldRouter proxy:", address(router));
        console2.log("  admin                   :", admin);
        console2.log("  timelock (UPGRADER)     :", timelock);
        console2.log("  lowWater  (USDC, 6dec)  :", lowWater);
        console2.log("  highWater (USDC, 6dec)  :", highWater);
        console2.log("");
        console2.log(">>> ENTITLE THIS PROXY ADDRESS IN USYC Entitlements 0xcc205224862c7641930c87679e98999d23c26113");
        console2.log(">>> (submit to Circle/Hashnote, same flow as keeper 0xcA02). Then grant FUNDER_ROLE/KEEPER_ROLE.");
    }
}
