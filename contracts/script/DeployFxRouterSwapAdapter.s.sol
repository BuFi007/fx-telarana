// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FxRouterSwapAdapter} from "../src/hub/FxRouterSwapAdapter.sol";

/// @notice FxSwapHook Phase 2.5 — deploy the production v4 swap adapter and wire
///         the 4 vault-backed V2 pools as directional routes (both ways each).
///
/// Live pool params confirmed on-chain via extsload(slot0): every FX pool is
/// initialized at fee=100 (0.01% stable tier), tickSpacing=1. QCAD is inverted
/// (currency0=QCAD). These calls are plain contract calls (no native-USDC
/// transfer) so forge CAN broadcast them on Arc — unlike seeding/swaps.
///
/// After this runs, the FxRouter owner must additionally:
///   1. adapter is authorized for the Router here IF FX_ROUTER env is set;
///      otherwise call `adapter.setAuthorizedCaller(fxRouter, true)` later.
///   2. `fxRouter.setSwapAdapter(address(adapter))`
///   3. `fxRouter.setPairAllowed(sell, buy, true)` for each of the 8 directions.
contract DeployFxRouterSwapAdapter is Script {
    address constant PM = 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34;
    address constant KEEPER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address constant MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address constant QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;

    address constant HOOK_EURC = 0x5bA91EB2f67302C947dFD35cC75D1dBcDb2CcAc8;
    address constant HOOK_AUDF = 0x7Af1ed939C2d4965490f1546b08b07e0BFdA0ac8;
    address constant HOOK_MXNB = 0xe9B0cD01eD5F83EEAe98522052Ae3a798dfb8aC8;
    address constant HOOK_QCAD = 0x6f80Ab06A4e359e9E6D025105945f02CcC98CAc8;

    uint24 constant FEE = 100; // 0.01% stable tier (confirmed on-chain)
    int24 constant TICK_SPACING = 1;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address fxRouter = vm.envOr("FX_ROUTER", address(0));

        vm.startBroadcast(pk);

        FxRouterSwapAdapter adapter = new FxRouterSwapAdapter(IPoolManager(PM), KEEPER);
        console2.log("FX_ROUTER_SWAP_ADAPTER", address(adapter));

        // currency0 < currency1 (v4 invariant). USDC (0x36..) sorts below
        // EURC/AUDF/MXNB; QCAD (0x23..) sorts below USDC → QCAD is currency0.
        _wirePair(adapter, USDC, EURC, _key(USDC, EURC, HOOK_EURC));
        _wirePair(adapter, USDC, AUDF, _key(USDC, AUDF, HOOK_AUDF));
        _wirePair(adapter, USDC, MXNB, _key(USDC, MXNB, HOOK_MXNB));
        _wirePair(adapter, QCAD, USDC, _key(QCAD, USDC, HOOK_QCAD));

        if (fxRouter != address(0)) {
            adapter.setAuthorizedCaller(fxRouter, true);
            console2.log("authorized FxRouter", fxRouter);
        } else {
            console2.log("FX_ROUTER not set - authorize the router separately");
        }

        vm.stopBroadcast();
    }

    /// @dev Set BOTH directions for the pair against the same PoolKey.
    function _wirePair(FxRouterSwapAdapter adapter, address a, address b, PoolKey memory key) internal {
        adapter.setRoute(a, b, key, true);
        adapter.setRoute(b, a, key, true);
    }

    /// @dev Build the sorted PoolKey. `lo` MUST be the lower-address token.
    function _key(address lo, address hi, address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
}
