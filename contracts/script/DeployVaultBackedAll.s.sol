// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";

/// @notice Pass 2b — deploy vault-backed FxSwapHooks for all 4 FX pairs pointing at FxOracleV2.
///         Vault + oracle already deployed. Each hook is mined to its v4 permission address.
///         QCAD is the inverted pair (token0=QCAD, token1=USDC).
contract DeployVaultBackedAll is Script {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant AUDF = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;
    address constant MXNB = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address constant QCAD = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;
    address constant PM = 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34;
    address constant ORACLE_V2 = 0xdA5Cd65521B64A7375C8d63EeDe52347783cEd74;
    address constant REGISTRY = 0x813232259c9b922e7571F15220617C80581f1464;
    address constant MORPHO = 0x3c9b95C6E7B23f094f066733E7797C8680760830;
    address constant VAULT = 0x0E63eff212382F2679c3A363F60e00b7A6d6e3E4;
    address constant KEEPER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        vm.startBroadcast(pk);
        console2.log("EURC_HOOK", _deploy(flags, USDC, EURC));
        console2.log("AUDF_HOOK", _deploy(flags, USDC, AUDF));
        console2.log("MXNB_HOOK", _deploy(flags, USDC, MXNB));
        console2.log("QCAD_HOOK", _deploy(flags, QCAD, USDC)); // inverted
        vm.stopBroadcast();
    }

    function _deploy(uint160 flags, address token0, address token1) internal returns (address hook) {
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode, abi.encode(PM, ORACLE_V2, REGISTRY, KEEPER, token0, token1, MORPHO, VAULT)
        );
        (address expected, bytes32 salt) = HookMiner.find(FACTORY, flags, creationCode, 200_000);
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(salt, creationCode));
        require(ok, "CREATE2 failed");
        assembly {
            hook := mload(add(ret, 20))
        }
        require(hook == expected, "addr != mined");
    }
}
