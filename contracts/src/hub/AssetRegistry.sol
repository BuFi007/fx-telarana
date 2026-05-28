// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AssetRegistry
/// @notice Source of truth for "what is this token and where does it live."
///         Maps a canonical symbol (e.g. "JPYC") to a config — decimals, bridge
///         strategy, liquidity-home chain — and to a per-chain token address
///         plus per-chain bridge endpoint.
///
///         Read by PoolRegistry, LiquidityRouter, and the Telarana gateway when
///         resolving cross-chain routes. One contract, JSON-config-driven, same
///         code on testnet and mainnet — only the registry entries change.
/// @dev    Admin-gated by multisig timelock in production (Phase 3 of the
///         decentralization spec). The companion of PoolRegistry — together
///         they form the Layer 1 / Layer 2 routing surface described in the
///         BUFX Hub-and-Spoke liquidity spec.
contract AssetRegistry is AccessControl {
    bytes32 public constant ASSET_ADMIN_ROLE = keccak256("ASSET_ADMIN_ROLE");

    /// @notice Bridge transport used to move an asset between chains.
    /// @dev    `Native` covers assets that exist at the same address on every
    ///         chain (JPYC) — the bridge field still tells callers HOW to move
    ///         it (typically Hyperlane warp route or the issuer's own bridge),
    ///         but cross-chain reads don't need an address translation.
    enum BridgeStrategy {
        None, //          Not cross-chain transferrable
        CCTP, //          Circle CCTP V2 (USDC, EURC after 2024)
        CircleGateway, // Circle's atomic gateway (USDC unified balance)
        Hyperlane, //     We deploy a warp route — most decentralized, we control
        Native //         Same address on all chains (JPYC) — bridge tells us HOW to move it
    }

    /// @notice Per-asset config registered once and read many times.
    /// @param symbol Canonical symbol, e.g. "JPYC".
    /// @param decimals Token decimals (typically 6 or 18).
    /// @param strategy Bridge transport used to move this asset cross-chain.
    /// @param liquidityHomeChainId Chain where the deepest external pool lives
    ///        (0 = no external liquidity; we self-LP on hub chains).
    /// @param enabled If false, the asset is registered but soft-paused.
    struct AssetConfig {
        string symbol;
        uint8 decimals;
        BridgeStrategy strategy;
        uint256 liquidityHomeChainId;
        bool enabled;
    }

    /// @notice assetKey (= keccak256(symbol)) → AssetConfig.
    mapping(bytes32 assetKey => AssetConfig) public assets;

    /// @notice Per-chain token address for an asset.
    mapping(bytes32 assetKey => mapping(uint256 chainId => address)) public perChainAddress;

    /// @notice Per-chain bridge endpoint for an asset (Hyperlane warp route,
    ///         CCTP TokenMessenger, etc.).
    mapping(bytes32 assetKey => mapping(uint256 chainId => address)) public bridgeContract;

    /// @notice Enumeration list of every registered asset key. Grows monotonically.
    bytes32[] public assetKeys;

    event AssetRegistered(bytes32 indexed assetKey, string symbol, BridgeStrategy strategy);
    event AssetEnabled(bytes32 indexed assetKey, bool enabled);
    event ChainAddressSet(bytes32 indexed assetKey, uint256 chainId, address tokenAddress);
    event BridgeContractSet(bytes32 indexed assetKey, uint256 chainId, address bridge);

    error AssetNotFound(bytes32 assetKey);
    error InvalidConfig();

    constructor(address admin) {
        if (admin == address(0)) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ASSET_ADMIN_ROLE, admin);
    }

    // ── Admin (multisig timelock in production) ─────────────────────

    /// @notice Register or overwrite an asset. Idempotent on `assetKeys` —
    ///         the enumeration list only grows on first registration.
    /// @param symbol Canonical symbol, e.g. "JPYC".
    /// @param decimals Token decimals.
    /// @param strategy Bridge transport.
    /// @param liquidityHomeChainId Chain hosting the deepest external pool.
    /// @return key The keccak256(symbol) handle used by every other view.
    function registerAsset(
        string calldata symbol,
        uint8 decimals,
        BridgeStrategy strategy,
        uint256 liquidityHomeChainId
    ) external onlyRole(ASSET_ADMIN_ROLE) returns (bytes32 key) {
        if (bytes(symbol).length == 0) revert InvalidConfig();
        key = assetKey(symbol);
        if (bytes(assets[key].symbol).length == 0) {
            assetKeys.push(key);
        }
        assets[key] = AssetConfig({
            symbol: symbol,
            decimals: decimals,
            strategy: strategy,
            liquidityHomeChainId: liquidityHomeChainId,
            enabled: true
        });
        emit AssetRegistered(key, symbol, strategy);
    }

    /// @notice Set the token address for `key` on `chainId`.
    function setChainAddress(bytes32 key, uint256 chainId, address tokenAddress)
        external
        onlyRole(ASSET_ADMIN_ROLE)
    {
        if (bytes(assets[key].symbol).length == 0) revert AssetNotFound(key);
        perChainAddress[key][chainId] = tokenAddress;
        emit ChainAddressSet(key, chainId, tokenAddress);
    }

    /// @notice Set the bridge endpoint for `key` on `chainId`. Typically a
    ///         Hyperlane warp route (`HypERC20Collateral` / `HypERC20Synthetic`)
    ///         or a CCTP `TokenMessengerV2`.
    function setBridgeContract(bytes32 key, uint256 chainId, address bridge)
        external
        onlyRole(ASSET_ADMIN_ROLE)
    {
        if (bytes(assets[key].symbol).length == 0) revert AssetNotFound(key);
        bridgeContract[key][chainId] = bridge;
        emit BridgeContractSet(key, chainId, bridge);
    }

    /// @notice Soft-enable / soft-pause an asset without unregistering it.
    function setEnabled(bytes32 key, bool enabled) external onlyRole(ASSET_ADMIN_ROLE) {
        if (bytes(assets[key].symbol).length == 0) revert AssetNotFound(key);
        assets[key].enabled = enabled;
        emit AssetEnabled(key, enabled);
    }

    // ── Read views ─────────────────────────

    /// @notice Canonical handle for a symbol. `assetKey("JPYC") == keccak256("JPYC")`.
    function assetKey(string memory symbol) public pure returns (bytes32) {
        return keccak256(bytes(symbol));
    }

    /// @notice Returns the full config for `key`. Reverts if the asset is not
    ///         registered (distinct from soft-disabled).
    function getAsset(bytes32 key) external view returns (AssetConfig memory) {
        if (bytes(assets[key].symbol).length == 0) revert AssetNotFound(key);
        return assets[key];
    }

    /// @notice Symbol-keyed convenience read for the per-chain token address.
    function tokenAddressOnChain(string memory symbol, uint256 chainId) external view returns (address) {
        return perChainAddress[assetKey(symbol)][chainId];
    }

    /// @notice Enumerate every registered asset key.
    function listAssets() external view returns (bytes32[] memory) {
        return assetKeys;
    }

    /// @notice Number of registered assets.
    function assetCount() external view returns (uint256) {
        return assetKeys.length;
    }
}
