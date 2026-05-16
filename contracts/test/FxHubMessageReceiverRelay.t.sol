// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxHubMessageReceiver} from "../src/hub/FxHubMessageReceiver.sol";
import {FxGatewayHook} from "../src/hub/FxGatewayHook.sol";
import {MockGatewayWallet, MockGatewayMinter} from "./mocks/MockGateway.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockMT {
    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) { return true; }
}

contract MockRegistry {
    // Minimal stub — never actually called from the relay tests.
}

contract FxHubMessageReceiverRelayTest is Test {
    FxHubMessageReceiver public hub;
    FxGatewayHook public hook;
    MockGatewayWallet public gwWallet;
    MockGatewayMinter public gwMinter;
    MockERC20 public usdc;
    MockMT public mt;
    MockRegistry public registry;

    address internal constant OWNER     = address(uint160(uint256(keccak256("relay.test.OWNER"))));
    address internal constant BUFX      = address(uint160(uint256(keccak256("relay.test.BUFX"))));
    address internal constant OUTSIDER  = address(uint160(uint256(keccak256("relay.test.OUTSIDER"))));
    address internal constant AUTHORITY = address(uint160(uint256(keccak256("relay.test.AUTHORITY"))));
    uint32  internal constant LOCAL_DOMAIN = 1;

    function setUp() public {
        usdc      = new MockERC20("USDC", "USDC", 6);
        mt        = new MockMT();
        registry  = new MockRegistry();
        gwWallet  = new MockGatewayWallet();
        gwMinter  = new MockGatewayMinter(address(usdc));

        // Deploy hub with OWNER as initial owner
        hub = new FxHubMessageReceiver(address(mt), address(usdc), address(registry), OWNER);

        // Deploy hook with HUB pointing at the hub above
        hook = new FxGatewayHook(
            address(usdc), address(gwWallet), address(gwMinter), address(hub), LOCAL_DOMAIN, AUTHORITY
        );

        // Owner wires the hook
        vm.prank(OWNER);
        hub.setGatewayHook(address(hook));

        // Pre-fund minter so it can transfer USDC on gatewayMint
        usdc.mint(address(gwMinter), 1_000_000e6);
    }

    // ── OWNERSHIP ────────────────────────────────────────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(hub.owner(), OWNER);
    }

    function test_transferOwnership_happyPath() public {
        address NEW_OWNER = address(uint160(uint256(keccak256("relay.test.NEW_OWNER"))));
        vm.prank(OWNER);
        hub.transferOwnership(NEW_OWNER);
        assertEq(hub.owner(), NEW_OWNER);
    }

    function test_transferOwnership_revertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(FxHubMessageReceiver.NotOwner.selector, OUTSIDER));
        vm.prank(OUTSIDER);
        hub.transferOwnership(OUTSIDER);
    }

    function test_transferOwnership_revertsOnZero() public {
        vm.expectRevert();
        vm.prank(OWNER);
        hub.transferOwnership(address(0));
    }

    // ── GATEWAY HOOK WIRING ──────────────────────────────────────────────

    function test_setGatewayHook_happyPath() public view {
        assertEq(hub.gatewayHook(), address(hook));
    }

    function test_setGatewayHook_revertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(FxHubMessageReceiver.NotOwner.selector, OUTSIDER));
        vm.prank(OUTSIDER);
        hub.setGatewayHook(address(0x1234));
    }

    function test_setGatewayHook_revertsOnZero() public {
        vm.expectRevert();
        vm.prank(OWNER);
        hub.setGatewayHook(address(0));
    }

    // ── RELAY CALLER WHITELIST ───────────────────────────────────────────

    function test_setRelayCaller_addsThenRemoves() public {
        vm.prank(OWNER);
        hub.setRelayCaller(BUFX, true);
        assertTrue(hub.relayCallers(BUFX));

        vm.prank(OWNER);
        hub.setRelayCaller(BUFX, false);
        assertFalse(hub.relayCallers(BUFX));
    }

    function test_setRelayCaller_revertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(FxHubMessageReceiver.NotOwner.selector, OUTSIDER));
        vm.prank(OUTSIDER);
        hub.setRelayCaller(BUFX, true);
    }

    // ── relayToRemoteHub ─────────────────────────────────────────────────

    function test_relayToRemoteHub_happyPath_fromOwner() public {
        uint256 amt = 100_000e6;

        // Fund owner with USDC + approve hub
        usdc.mint(OWNER, amt);
        vm.prank(OWNER);
        usdc.approve(address(hub), amt);

        vm.prank(OWNER);
        hub.relayToRemoteHub(amt);

        // USDC should be locked into Gateway under AUTHORITY's balance
        assertEq(gwWallet.available(address(usdc), AUTHORITY), amt, "Gateway credited authority");
        assertEq(usdc.balanceOf(OWNER), 0,                              "owner debited");
        assertEq(usdc.balanceOf(address(hub)), 0,                       "hub forwards everything");
        assertEq(usdc.balanceOf(address(hook)), 0,                      "hook forwards everything");
    }

    function test_relayToRemoteHub_happyPath_fromWhitelistedBufx() public {
        uint256 amt = 50_000e6;
        vm.prank(OWNER);
        hub.setRelayCaller(BUFX, true);

        usdc.mint(BUFX, amt);
        vm.prank(BUFX);
        usdc.approve(address(hub), amt);

        vm.prank(BUFX);
        hub.relayToRemoteHub(amt);

        assertEq(gwWallet.available(address(usdc), AUTHORITY), amt);
    }

    function test_relayToRemoteHub_revertsForOutsider() public {
        vm.expectRevert(abi.encodeWithSelector(FxHubMessageReceiver.NotAuthorizedRelayer.selector, OUTSIDER));
        vm.prank(OUTSIDER);
        hub.relayToRemoteHub(1e6);
    }

    function test_relayToRemoteHub_revertsOnZeroAmount() public {
        vm.expectRevert(FxHubMessageReceiver.ZeroAmount.selector);
        vm.prank(OWNER);
        hub.relayToRemoteHub(0);
    }

    function test_relayToRemoteHub_dropsApprovalAfterCall() public {
        uint256 amt = 10_000e6;
        usdc.mint(OWNER, amt);
        vm.prank(OWNER);
        usdc.approve(address(hub), amt);

        vm.prank(OWNER);
        hub.relayToRemoteHub(amt);

        assertEq(usdc.allowance(address(hub), address(hook)), 0, "hub-hook approval scrubbed");
    }

    // ── relayMintFromRemote ──────────────────────────────────────────────

    function test_relayMintFromRemote_happyPath() public {
        uint256 mintAmt = 25_000e6;
        gwMinter.setNextMint(false, mintAmt, address(hook));

        vm.prank(OWNER);
        uint256 minted = hub.relayMintFromRemote("payload", "sig");

        assertEq(minted, mintAmt);
        // USDC should have landed at hub (hook forwards to its HUB)
        assertEq(usdc.balanceOf(address(hub)), mintAmt);
    }

    function test_relayMintFromRemote_revertsForOutsider() public {
        vm.expectRevert(abi.encodeWithSelector(FxHubMessageReceiver.NotAuthorizedRelayer.selector, OUTSIDER));
        vm.prank(OUTSIDER);
        hub.relayMintFromRemote("p", "s");
    }

    function test_relayMintFromRemote_revertsIfHookUnset() public {
        // Build a fresh hub WITHOUT calling setGatewayHook
        FxHubMessageReceiver freshHub = new FxHubMessageReceiver(
            address(mt), address(usdc), address(registry), OWNER
        );
        vm.expectRevert(FxHubMessageReceiver.GatewayHookNotSet.selector);
        vm.prank(OWNER);
        freshHub.relayMintFromRemote("p", "s");
    }
}
