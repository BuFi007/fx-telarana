// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

interface IFxOracleV2FeedAdmin {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function pythFeedOf(address token) external view returns (bytes32);
    function pythFeedInvertedOf(address token) external view returns (bool);
    function setPythFeedConfig(address token, bytes32 pythFeedId, bool inverted) external;
}

/// @notice Arc-only repair for the live FxOracleV2 feed table.
///
/// Adds the missing JPYC and cirBTC Pyth feed configs:
///   * JPYC   -> JPY/USD, inverted=true
///   * cirBTC -> BTC/USD, inverted=false
///
/// This script is intentionally guarded for ops usage. Dry-run it first, and
/// only add `--broadcast` after the runbook gates have passed.
contract RepairFxOracleV2Feeds is Script {
    uint256 internal constant ARC_CHAIN_ID = 5_042_002;

    address internal constant DEFAULT_FX_ORACLE_V2 = 0xdA5Cd65521B64A7375C8d63EeDe52347783cEd74;
    address internal constant EXPECTED_ADMIN = 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69;

    address internal constant JPYC = 0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29;
    address internal constant CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;

    bytes32 internal constant PYTH_JPY_USD = 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52;
    bytes32 internal constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    string internal constant CONFIRMATION = "SET_JPYC_AND_CIRBTC_PYTH_FEEDS_ON_ARC";

    error WrongChain(uint256 chainId);
    error MissingConfirmation();
    error MissingCode(address target);
    error MissingAdminRole(address oracle, address signer);
    error UnexpectedAdminKey(address signer);

    function run() external {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);
        if (keccak256(bytes(vm.envOr("CONFIRM_FX_ORACLE_V2_REPAIR", string("")))) != keccak256(bytes(CONFIRMATION))) {
            revert MissingConfirmation();
        }

        uint256 pk = vm.envUint("FX_ORACLE_V2_ADMIN_PRIVATE_KEY");
        address signer = vm.addr(pk);
        if (signer != EXPECTED_ADMIN) revert UnexpectedAdminKey(signer);

        address oracleAddr = vm.envOr("FX_ORACLE_V2", DEFAULT_FX_ORACLE_V2);
        if (oracleAddr.code.length == 0) revert MissingCode(oracleAddr);

        IFxOracleV2FeedAdmin oracle = IFxOracleV2FeedAdmin(oracleAddr);
        bytes32 adminRole = oracle.DEFAULT_ADMIN_ROLE();
        if (!oracle.hasRole(adminRole, signer)) revert MissingAdminRole(oracleAddr, signer);

        console2.log("============================================");
        console2.log("Repairing FxOracleV2 Pyth feed configs");
        console2.log("============================================");
        console2.log("chainId      ", block.chainid);
        console2.log("oracle       ", oracleAddr);
        console2.log("admin signer ", signer);
        _logFeed("JPYC before  ", oracle, JPYC);
        _logFeed("cirBTC before", oracle, CIRBTC);

        vm.startBroadcast(pk);
        oracle.setPythFeedConfig(JPYC, PYTH_JPY_USD, true);
        oracle.setPythFeedConfig(CIRBTC, PYTH_BTC_USD, false);
        vm.stopBroadcast();

        _logFeed("JPYC after   ", oracle, JPYC);
        _logFeed("cirBTC after ", oracle, CIRBTC);
    }

    function _logFeed(string memory label, IFxOracleV2FeedAdmin oracle, address token) internal view {
        console2.log(label, token);
        console2.log("  feed      ", uint256(oracle.pythFeedOf(token)));
        console2.log("  inverted  ", oracle.pythFeedInvertedOf(token));
    }
}
