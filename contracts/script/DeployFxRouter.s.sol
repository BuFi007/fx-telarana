// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FxRouter} from "../src/hub/FxRouter.sol";
import {FxRouterSwapAdapter} from "../src/hub/FxRouterSwapAdapter.sol";
import {FxRouterLib} from "../src/libraries/FxRouterLib.sol";

/// @notice FxSwapHook Phase 2.5 — deploy the FxRouter (signed-intent + Permit2
///         entry point) pointed at the already-deployed FxRouterSwapAdapter,
///         then wire both sides:
///           * FxRouter.setPairAllowed for the 8 FX directions
///           * adapter.setAuthorizedCaller(router, true)
///
/// Deploy from KEEPER (owns the adapter; becomes the Router owner) so every
/// wiring call is authorized in one broadcast. Plain calls / no native-USDC
/// transfer → forge can broadcast on Arc. Permit2 is live on Arc at the
/// canonical address. PR-6 hands Router ownership to a timelock later.
contract DeployFxRouter is Script {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ADAPTER = 0xe9147f799C1d65d1bAcFD0fE019d8c46531ef917;
    address constant KEEPER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address constant MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address constant QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        // Adapter is baked in at construction; treasury = KEEPER (canary);
        // maxFeeBps = the 50bps hard cap (admin still picks per-intent fee).
        FxRouter router = new FxRouter(PERMIT2, ADAPTER, KEEPER, FxRouterLib.MAX_FEE_BPS_HARD_CAP, KEEPER);
        console2.log("FX_ROUTER", address(router));

        // Allow all 8 FX directions.
        _allowBoth(router, USDC, EURC);
        _allowBoth(router, USDC, AUDF);
        _allowBoth(router, USDC, MXNB);
        _allowBoth(router, USDC, QCAD);

        // Let the Router call the adapter (KEEPER owns the adapter).
        FxRouterSwapAdapter(ADAPTER).setAuthorizedCaller(address(router), true);
        console2.log("authorized router on adapter", address(router));

        vm.stopBroadcast();
    }

    function _allowBoth(FxRouter router, address a, address b) internal {
        router.setPairAllowed(a, b, true);
        router.setPairAllowed(b, a, true);
    }
}
