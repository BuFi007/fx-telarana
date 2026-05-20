// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

interface IOldAccessControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function revokeRole(bytes32 role, address account) external;
}

interface IOldPerpClearinghouse is IOldAccessControl {
    function LIQUIDATION_ENGINE_ROLE() external view returns (bytes32);
    function pause() external;
    function paused() external view returns (bool);
}

interface IOldLiquidationEngine {
    function pause() external;
    function paused() external view returns (bool);
}

/// @notice Retires pre-sprint-1 perp stacks after the newly deployed stack is
///         configured and proven. This script does not migrate state.
contract RetireOldPerpStack is Script {
    uint256 internal constant FUJI_CHAIN_ID = 43_113;
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant FUJI_OLD_CLEARINGHOUSE = 0x22013f712190034D8Ee43F3894461c27709E74AC;
    address internal constant FUJI_OLD_LIQUIDATION = 0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d;
    address internal constant ARC_OLD_CLEARINGHOUSE = 0x6A265045D9A3291D2881d77DDC62e2781A2418c5;
    address internal constant ARC_OLD_LIQUIDATION = 0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2;

    error UnsupportedChain(uint256 chainId);
    error MissingCode(string label, address target);
    error OldLiquidationEngineStillAuthorized(address clearinghouse, address liquidationEngine);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        (address defaultClearinghouse, address defaultLiquidation) = _defaultsForChain();
        address oldClearinghouse = vm.envOr("OLD_PERP_CLEARINGHOUSE", defaultClearinghouse);
        address oldLiquidation = vm.envOr("OLD_PERP_LIQUIDATION", defaultLiquidation);

        _expectCode("old clearinghouse", oldClearinghouse);
        _expectCode("old liquidation engine", oldLiquidation);

        IOldPerpClearinghouse clearinghouse = IOldPerpClearinghouse(oldClearinghouse);
        IOldLiquidationEngine liquidation = IOldLiquidationEngine(oldLiquidation);
        bytes32 liquidationRole = clearinghouse.LIQUIDATION_ENGINE_ROLE();

        console2.log("============================================");
        console2.log("Retiring old Phase B-E perp stack");
        console2.log("============================================");
        console2.log("chainId                    ", block.chainid);
        console2.log("old clearinghouse          ", oldClearinghouse);
        console2.log("old liquidation            ", oldLiquidation);
        console2.log("old liquidation authorized ", clearinghouse.hasRole(liquidationRole, oldLiquidation));
        console2.log("old clearinghouse paused   ", clearinghouse.paused());
        console2.log("old liquidation paused     ", liquidation.paused());

        vm.startBroadcast(pk);
        if (clearinghouse.hasRole(liquidationRole, oldLiquidation)) {
            clearinghouse.revokeRole(liquidationRole, oldLiquidation);
        }
        if (!clearinghouse.paused()) {
            clearinghouse.pause();
        }
        if (!liquidation.paused()) {
            liquidation.pause();
        }
        vm.stopBroadcast();

        if (clearinghouse.hasRole(liquidationRole, oldLiquidation)) {
            revert OldLiquidationEngineStillAuthorized(oldClearinghouse, oldLiquidation);
        }

        console2.log("retired: old liquidation role revoked and both old contracts paused");
    }

    function _defaultsForChain() internal view returns (address clearinghouse, address liquidation) {
        if (block.chainid == FUJI_CHAIN_ID) return (FUJI_OLD_CLEARINGHOUSE, FUJI_OLD_LIQUIDATION);
        if (block.chainid == ARC_CHAIN_ID) return (ARC_OLD_CLEARINGHOUSE, ARC_OLD_LIQUIDATION);
        revert UnsupportedChain(block.chainid);
    }

    function _expectCode(string memory label, address target) internal view {
        if (target.code.length == 0) revert MissingCode(label, target);
    }
}
