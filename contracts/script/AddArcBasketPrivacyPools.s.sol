// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrivacyPool} from "privacy-pools/interfaces/IPrivacyPool.sol";

import {FxPrivacyPool} from "../src/hub/FxPrivacyPool.sol";

interface IEntrypointAdmin {
    function registerPool(
        IERC20 _asset,
        IPrivacyPool _pool,
        uint256 _minimumDepositAmount,
        uint256 _vettingFeeBPS,
        uint256 _maxRelayFeeBPS
    ) external;
}

/// @notice Add shielded pools for the four newer Arc Testnet basket tokens
///         (MXNB, QCAD, cirBTC, AUDF) to the live privacy hub. Mirrors
///         `AddArcEurcPool.s.sol` but does all four in one broadcast and
///         pins each pool to 100% hot mode (no Morpho rehyp) since the
///         canonical Morpho markets we just created are USDC-loan, not
///         asset-loan, so the registry has no usable (asset, USDC) market
///         to rehyp INTO. The dummy collateral arg satisfies the
///         constructor's non-zero check; `hotReservePct = 10000` skips
///         the rehyp code path entirely (see FxPrivacyPool._rebalance).
///
///         Each pool gets registered into the existing FxPrivacyEntrypoint
///         registry with sensible minimums + relay fee caps.
///
///         Re-using the live verifier pair (WithdrawalVerifier +
///         CommitmentVerifier) deployed by DeployPrivacyHookArc; no new
///         circuit / vkey work needed.
contract AddArcBasketPrivacyPools is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address constant DEFAULT_USDC       = 0x3600000000000000000000000000000000000000;
    address constant DEFAULT_MORPHO     = 0x3c9b95C6E7B23f094f066733E7797C8680760830;
    address constant DEFAULT_REGISTRY   = 0x813232259c9b922e7571F15220617C80581f1464;
    address constant DEFAULT_ENTRYPOINT = 0xD11cDdd1f04e850d3810a71608A49907c80f2736;
    address constant DEFAULT_WV         = 0x7f0326cea0796e31ED38F01B1E8660fAAd7BB6eE;
    address constant DEFAULT_CV         = 0x9056fAcd889a94E4aCBA8cbc4c8a81ED47Ba8EA0;

    address constant DEFAULT_MXNB   = 0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461;
    address constant DEFAULT_QCAD   = 0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d;
    address constant DEFAULT_CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
    address constant DEFAULT_AUDF   = 0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b;

    uint16  constant FULL_HOT_PCT = 10_000;
    uint256 constant VETTING_FEE_BPS   = 0;
    uint256 constant MAX_RELAY_FEE_BPS = 500;

    struct PoolSpec {
        string  symbol;
        address asset;
        uint256 minimumDeposit;
        uint8   decimals;
    }

    error WrongChain(uint256 chainId);
    error MissingCode(string label, address target);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address usdc       = vm.envOr("ARC_USDC",               DEFAULT_USDC);
        address morpho     = vm.envOr("ARC_MORPHO",             DEFAULT_MORPHO);
        address registry   = vm.envOr("ARC_REGISTRY",           DEFAULT_REGISTRY);
        address entrypoint = vm.envOr("ARC_PRIVACY_ENTRYPOINT", DEFAULT_ENTRYPOINT);
        address wv         = vm.envOr("ARC_PRIVACY_WV",         DEFAULT_WV);
        address cv         = vm.envOr("ARC_PRIVACY_CV",         DEFAULT_CV);

        PoolSpec[4] memory specs;
        // minimumDeposit aligned to 1 unit of each token (decimals from token).
        specs[0] = PoolSpec({symbol: "MXNB",   asset: vm.envOr("ARC_MXNB",   DEFAULT_MXNB),   minimumDeposit: 1e6,  decimals: 6});
        specs[1] = PoolSpec({symbol: "QCAD",   asset: vm.envOr("ARC_QCAD",   DEFAULT_QCAD),   minimumDeposit: 1e6,  decimals: 6});
        specs[2] = PoolSpec({symbol: "cirBTC", asset: vm.envOr("ARC_CIRBTC", DEFAULT_CIRBTC), minimumDeposit: 1e15, decimals: 18}); // 0.001 cirBTC
        specs[3] = PoolSpec({symbol: "AUDF",   asset: vm.envOr("ARC_AUDF",   DEFAULT_AUDF),   minimumDeposit: 1e6,  decimals: 6});

        _assertCode("USDC (dummy collateral)", usdc);
        _assertCode("MorphoBlue",   morpho);
        _assertCode("FxMarketRegistry", registry);
        _assertCode("FxPrivacyEntrypoint", entrypoint);
        _assertCode("WithdrawalVerifier",  wv);
        _assertCode("CommitmentVerifier",  cv);
        for (uint256 i = 0; i < specs.length; i++) {
            _assertCode(specs[i].symbol, specs[i].asset);
        }

        console2.log("============================================");
        console2.log("Arc Testnet: add shielded pools for basket tokens");
        console2.log("============================================");
        console2.log("deployer            ", deployer);
        console2.log("entrypoint          ", entrypoint);
        console2.log("usdc (dummy collat) ", usdc);

        address[4] memory pools;

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < specs.length; i++) {
            FxPrivacyPool pool = new FxPrivacyPool(
                entrypoint,
                wv,
                cv,
                specs[i].asset,
                deployer,
                morpho,
                registry,
                usdc // dummy collateral; rehyp disabled below
            );

            // 100% hot — no Morpho rehyp. Skips the registry.paramsOf
            // lookup that would otherwise revert for unregistered (asset, USDC).
            pool.setHotReservePct(FULL_HOT_PCT);

            IEntrypointAdmin(entrypoint).registerPool(
                IERC20(specs[i].asset),
                IPrivacyPool(address(pool)),
                specs[i].minimumDeposit,
                VETTING_FEE_BPS,
                MAX_RELAY_FEE_BPS
            );

            pools[i] = address(pool);
        }
        vm.stopBroadcast();

        console2.log("============================================");
        console2.log("Pools registered:");
        for (uint256 i = 0; i < specs.length; i++) {
            console2.log("");
            console2.log("symbol  ", specs[i].symbol);
            console2.log("asset   ", specs[i].asset);
            console2.log("pool    ", pools[i]);
            console2.log("minDep  ", specs[i].minimumDeposit);
        }

        // Write a manifest fragment that downstream code can pick up
        // alongside the existing privacy-hook-arc.json.
        string memory manifestPath = vm.envOr(
            "ARC_PRIVACY_BASKET_PATH",
            string(abi.encodePacked("../deployments/arc-privacy-basket-", vm.toString(block.chainid), ".json"))
        );
        _writeManifest(manifestPath, deployer, entrypoint, specs, pools);
    }

    function _assertCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert MissingCode(label, target);
    }

    function _writeManifest(
        string memory path,
        address deployer,
        address entrypoint,
        PoolSpec[4] memory specs,
        address[4] memory pools
    ) internal {
        string memory root = "arcPrivacyBasket";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "exportedBlockNumber", block.number);
        vm.serializeUint(root, "exportedBlockTimestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "FxPrivacyEntrypoint", entrypoint);
        for (uint256 i = 0; i < specs.length; i++) {
            string memory key = specs[i].symbol;
            vm.serializeAddress(root, string.concat(key, "_asset"), specs[i].asset);
            vm.serializeAddress(root, string.concat(key, "_pool"), pools[i]);
            vm.serializeUint(root, string.concat(key, "_minimumDeposit"), specs[i].minimumDeposit);
        }
        vm.serializeUint(root, "vettingFeeBPS", VETTING_FEE_BPS);
        vm.serializeUint(root, "maxRelayFeeBPS", MAX_RELAY_FEE_BPS);
        vm.serializeUint(root, "hotReservePct", FULL_HOT_PCT);
        string memory json = vm.serializeString(
            root,
            "source",
            "AddArcBasketPrivacyPools.s.sol -- pools deployed in 100%-hot mode (no Morpho rehyp)"
        );
        vm.writeJson(json, path);
        console2.log("manifest          ", path);
    }
}
