// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

import {SharedFxVault} from "../src/vault/SharedFxVault.sol";
import {FxSwapHook} from "../src/hub/FxSwapHook.sol";

/// @notice P3 canary — deploy the SharedFxVault (UUPS) + a vault-backed FxSwapHook for USDC/EURC
///         on Arc Testnet. Capital migration (allowHook, fundJunior, pool init) is done via cast
///         afterward (native USDC can't be moved inside a forge run — Arc blocklist precompile).
///
/// CANARY NOTE: admin == timelock == KEEPER for the testnet canary, so KEEPER controls upgrades
/// without delay. Mainnet MUST pass a real TimelockController as `timelock`.
///
/// Required env: DEPLOYER_PRIVATE_KEY (a clean-nonce key, e.g. DEMO_TAKER — NOT KEEPER/matcher or
/// MAKER/pusher). Run: forge script script/DeployVaultBackedEurc.s.sol --rpc-url $ARC_RPC_URL --broadcast -vvv
contract DeployVaultBackedEurc is Script {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address constant PM = 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34;
    address constant ORACLE = 0x77b3A3B420dB98B01085b8C46a753Ed9879e2865;
    address constant REGISTRY = 0x813232259c9b922e7571F15220617C80581f1464;
    address constant MORPHO = 0x3c9b95C6E7B23f094f066733E7797C8680760830;
    address constant KEEPER = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    // Live USDC-loan market on MORPHO (idToMarketParams readback, M2_USDC_EURC).
    address constant M_ORACLE = 0x955AAEE698aaA03d5bc32F16434cef78b8Ee1fc7;
    address constant M_IRM = 0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1;
    uint256 constant M_LLTV = 860000000000000000;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        MarketParams memory mkt = MarketParams({
            loanToken: USDC,
            collateralToken: EURC,
            oracle: M_ORACLE,
            irm: M_IRM,
            lltv: M_LLTV
        });

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        vm.startBroadcast(pk);

        // 1) Vault: implementation + UUPS proxy (admin = timelock = KEEPER for the canary).
        SharedFxVault impl = new SharedFxVault();
        bytes memory init = abi.encodeCall(
            SharedFxVault.initialize, (IERC20(USDC), KEEPER, KEEPER, PM, ORACLE, IMorpho(MORPHO), mkt)
        );
        address vault = address(new ERC1967Proxy(address(impl), init));

        // 2) Vault-backed hook at a permission-encoding address (CREATE2 via the std factory).
        bytes memory creationCode = abi.encodePacked(
            type(FxSwapHook).creationCode, abi.encode(PM, ORACLE, REGISTRY, KEEPER, USDC, EURC, MORPHO, vault)
        );
        (address expected, bytes32 salt) = HookMiner.find(FACTORY, flags, creationCode, 200_000);
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(salt, creationCode));
        require(ok, "hook CREATE2 failed");
        address hook;
        assembly {
            hook := mload(add(ret, 20))
        }
        require(hook == expected, "hook addr != mined");

        vm.stopBroadcast();

        console2.log("VAULT_IMPL", address(impl));
        console2.log("VAULT     ", vault);
        console2.log("HOOK      ", hook);
        console2.logBytes32(salt);
    }
}
