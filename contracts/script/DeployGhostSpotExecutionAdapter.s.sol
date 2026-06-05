// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FxSpotSwapAdapter} from "../src/hub/FxExecutionAdapter.sol";

interface IPrivacyEntrypointExecutionAdmin {
    function executionAdapter(uint256 adapterId) external view returns (address);
    function registerExecutionAdapter(uint256 adapterId, FxSpotSwapAdapter adapter) external;
    function swapAdapter() external view returns (address);
    function setSwapAdapter(address newAdapter) external;
}

interface IFxRouterSwapAdapterAdmin {
    function authorizedCaller(address caller) external view returns (bool);
    function setAuthorizedCaller(address caller, bool authorized) external;
}

interface ISpotExecutionAdapterView {
    function SWAP() external view returns (address);
}

/// @notice Wire Ghost-mode private spot swaps on Arc.
contract DeployGhostSpotExecutionAdapter is Script {
    uint256 constant SPOT_ADAPTER_ID = 3;

    address constant ARC_PRIVACY_ENTRYPOINT = 0xD11cDdd1f04e850d3810a71608A49907c80f2736;
    address constant ARC_FX_ROUTER_SWAP_ADAPTER = 0xe9147f799C1d65d1bAcFD0fE019d8c46531ef917;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        IPrivacyEntrypointExecutionAdmin entrypoint =
            IPrivacyEntrypointExecutionAdmin(ARC_PRIVACY_ENTRYPOINT);
        IFxRouterSwapAdapterAdmin swapAdapter =
            IFxRouterSwapAdapterAdmin(ARC_FX_ROUTER_SWAP_ADAPTER);

        address existing = entrypoint.executionAdapter(SPOT_ADAPTER_ID);
        console2.log("deployer", deployer);
        console2.log("entrypoint", ARC_PRIVACY_ENTRYPOINT);
        console2.log("swapAdapter", ARC_FX_ROUTER_SWAP_ADAPTER);
        console2.log("entrypoint.swapAdapter()", entrypoint.swapAdapter());
        console2.log("existing executionAdapter(3)", existing);

        bool needsEntrypointAuth = !swapAdapter.authorizedCaller(ARC_PRIVACY_ENTRYPOINT);
        bool needsCrossCurrencyRepoint = entrypoint.swapAdapter() != ARC_FX_ROUTER_SWAP_ADAPTER;

        if (existing != address(0)) {
            address existingSwap = ISpotExecutionAdapterView(existing).SWAP();
            console2.log("existing executionAdapter(3).SWAP()", existingSwap);
            if (existingSwap == ARC_FX_ROUTER_SWAP_ADAPTER) {
                bool needsSpotAuth = !swapAdapter.authorizedCaller(existing);
                if (needsSpotAuth || needsEntrypointAuth || needsCrossCurrencyRepoint) {
                    vm.startBroadcast(pk);
                    if (needsSpotAuth) swapAdapter.setAuthorizedCaller(existing, true);
                    if (needsEntrypointAuth) swapAdapter.setAuthorizedCaller(ARC_PRIVACY_ENTRYPOINT, true);
                    if (needsCrossCurrencyRepoint) entrypoint.setSwapAdapter(ARC_FX_ROUTER_SWAP_ADAPTER);
                    vm.stopBroadcast();
                    console2.log("v4 swap adapter wiring refreshed");
                }
                return;
            }
            vm.startBroadcast(pk);
            FxSpotSwapAdapter replacementSpotAdapter =
                new FxSpotSwapAdapter(ARC_FX_ROUTER_SWAP_ADAPTER, ARC_PRIVACY_ENTRYPOINT);
            if (needsEntrypointAuth) swapAdapter.setAuthorizedCaller(ARC_PRIVACY_ENTRYPOINT, true);
            swapAdapter.setAuthorizedCaller(address(replacementSpotAdapter), true);
            if (needsCrossCurrencyRepoint) entrypoint.setSwapAdapter(ARC_FX_ROUTER_SWAP_ADAPTER);
            entrypoint.registerExecutionAdapter(SPOT_ADAPTER_ID, replacementSpotAdapter);
            vm.stopBroadcast();
            console2.log("replaced executionAdapter(3)", address(replacementSpotAdapter));
            return;
        }

        vm.startBroadcast(pk);
        FxSpotSwapAdapter spotAdapter =
            new FxSpotSwapAdapter(ARC_FX_ROUTER_SWAP_ADAPTER, ARC_PRIVACY_ENTRYPOINT);
        if (needsEntrypointAuth) swapAdapter.setAuthorizedCaller(ARC_PRIVACY_ENTRYPOINT, true);
        swapAdapter.setAuthorizedCaller(address(spotAdapter), true);
        if (needsCrossCurrencyRepoint) entrypoint.setSwapAdapter(ARC_FX_ROUTER_SWAP_ADAPTER);
        entrypoint.registerExecutionAdapter(SPOT_ADAPTER_ID, spotAdapter);
        vm.stopBroadcast();

        console2.log("FxSpotSwapAdapter", address(spotAdapter));
        console2.log("registered executionAdapter(3)", address(spotAdapter));
    }
}
