// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxFixedRateSwapAdapter} from "../src/hub/FxFixedRateSwapAdapter.sol";
import {IFxRouterSwapAdapter} from "../src/hub/FxRouter.sol";

interface IPrivacyEntrypointAdmin {
    function setSwapAdapter(IFxRouterSwapAdapter _newAdapter) external;
    function setCrossCurrencyEnabled(IERC20 _asset, bool _enabled) external;
    function swapAdapter() external view returns (IFxRouterSwapAdapter);
    function crossCurrencyEnabled(IERC20 _asset) external view returns (bool);
}

/// @notice Track B v1 (B-fast) — deploy a fixed-rate swap adapter on Arc,
///         fund it with seed liquidity, wire it to the live privacy
///         entrypoint, and enable cross-currency for both shielded assets.
///
///         End state: a user with a shielded USDC pool note can call
///         `relayCrossCurrency` with `buyToken = EURC` and receive real
///         Circle EURC on a fresh address, atomically. Same in reverse.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY    — must equal the entrypoint OWNER_ROLE
///                             holder (set/enable calls are owner-only).
///
/// Optional env (Arc-sensible defaults):
///   ARC_USDC                default 0x3600...0000
///   ARC_EURC                default 0x89B5...D72a
///   ARC_PRIVACY_ENTRYPOINT  default 0xd11c...2736
///   ADAPTER_SEED_USDC       default 1_000_000 (1 USDC, 6 dec)
///   ADAPTER_SEED_EURC       default 1_000_000 (1 EURC, 6 dec)
///   RATE_USDC_EURC          default 0.92e18 (1 USDC → 0.92 EURC)
///   RATE_EURC_USDC          default 1.08e18 (1 EURC → 1.08 USDC)
contract DeployArcFixedRateAdapter is Script {
    address constant DEFAULT_USDC       = 0x3600000000000000000000000000000000000000;
    address constant DEFAULT_EURC       = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant DEFAULT_ENTRYPOINT = 0xD11cDdd1f04e850d3810a71608A49907c80f2736;

    uint256 constant DEFAULT_SEED_USDC      = 1_000_000;          // 1 USDC
    uint256 constant DEFAULT_SEED_EURC      = 1_000_000;          // 1 EURC
    uint256 constant DEFAULT_RATE_USDC_EURC = 0.92e18;            // 1 USDC → 0.92 EURC
    uint256 constant DEFAULT_RATE_EURC_USDC = 1.08e18;            // 1 EURC → 1.08 USDC

    function run() external {
        uint256 pk       = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IERC20 usdc       = IERC20(vm.envOr("ARC_USDC",              DEFAULT_USDC));
        IERC20 eurc       = IERC20(vm.envOr("ARC_EURC",              DEFAULT_EURC));
        IPrivacyEntrypointAdmin entrypoint =
            IPrivacyEntrypointAdmin(vm.envOr("ARC_PRIVACY_ENTRYPOINT", DEFAULT_ENTRYPOINT));

        uint256 seedUsdc      = vm.envOr("ADAPTER_SEED_USDC",      DEFAULT_SEED_USDC);
        uint256 seedEurc      = vm.envOr("ADAPTER_SEED_EURC",      DEFAULT_SEED_EURC);
        uint256 rateUsdcEurc  = vm.envOr("RATE_USDC_EURC",         DEFAULT_RATE_USDC_EURC);
        uint256 rateEurcUsdc  = vm.envOr("RATE_EURC_USDC",         DEFAULT_RATE_EURC_USDC);

        // Arc's USDC at 0x3600...0000 is a precompile-backed ERC-20 that
        // Foundry's local REVM can't simulate (the inner call into
        // 0x1800...0000 trips StackUnderflow). We therefore SKIP funding
        // the adapter from inside this script and require the operator
        // to send the seed transfers via `cast send` after deploy:
        //
        //   cast send <USDC> "transfer(address,uint256)" <adapter> 1000000 ...
        //   cast send <EURC> "transfer(address,uint256)" <adapter> 1000000 ...
        //
        // (EURC alone would simulate fine — but to keep the script
        // symmetric and pre-broadcast simulation green, we lift BOTH
        // transfers out.)
        seedUsdc; // silence unused warning
        seedEurc;
        eurc;     // silence unused warning

        console2.log("deployer         ", deployer);
        console2.log("USDC             ", address(usdc));
        console2.log("EURC             ", address(eurc));
        console2.log("FxPrivacyEntrypoint", address(entrypoint));
        console2.log("seedUsdc         ", seedUsdc);
        console2.log("seedEurc         ", seedEurc);
        console2.log("rate USDC->EURC  ", rateUsdcEurc);
        console2.log("rate EURC->USDC  ", rateEurcUsdc);

        vm.startBroadcast(pk);

        // 1) Deploy adapter, deployer holds ownership.
        FxFixedRateSwapAdapter adapter = new FxFixedRateSwapAdapter(deployer);

        // 2) Set bidirectional rates + enable both pairs.
        adapter.setRate(address(usdc), address(eurc), rateUsdcEurc);
        adapter.setRate(address(eurc), address(usdc), rateEurcUsdc);
        adapter.setEnabled(address(usdc), address(eurc), true);
        adapter.setEnabled(address(eurc), address(usdc), true);

        // 2.5) Codex round-11 HIGH: authorize the privacy entrypoint as
        //      the only caller. Without this, any EOA can drain seed
        //      liquidity by calling swapExactInput directly.
        adapter.setAuthorizedCaller(address(entrypoint), true);

        // 3) Wire the entrypoint. setSwapAdapter + setCrossCurrencyEnabled
        //    are owner-only; deployer holds OWNER_ROLE from the original
        //    privacy hook deploy.
        entrypoint.setSwapAdapter(IFxRouterSwapAdapter(address(adapter)));
        entrypoint.setCrossCurrencyEnabled(usdc, true);
        entrypoint.setCrossCurrencyEnabled(eurc, true);

        vm.stopBroadcast();

        console2.log("=================================================");
        console2.log("Arc Testnet: cross-currency relay wired (B-fast)");
        console2.log("=================================================");
        console2.log("FxFixedRateSwapAdapter ", address(adapter));
        console2.log("");
        console2.log("NEXT: fund the adapter from deployer's wallet:");
        console2.log("  cast send <USDC> 'transfer(address,uint256)' <adapter> 1000000 --rpc-url $ARC_RPC --private-key $DEPLOYER_PRIVATE_KEY");
        console2.log("  cast send <EURC> 'transfer(address,uint256)' <adapter> 1000000 --rpc-url $ARC_RPC --private-key $DEPLOYER_PRIVATE_KEY");
        console2.log("");
        console2.log("Then verify the wiring:");
        console2.log("  cast call <entrypoint> 'swapAdapter()(address)' --rpc-url $ARC_RPC");
        console2.log("  cast call <entrypoint> 'crossCurrencyEnabled(address)(bool)' <USDC|EURC> --rpc-url $ARC_RPC");
    }
}
