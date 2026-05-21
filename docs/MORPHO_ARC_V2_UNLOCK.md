# Morpho Arc Testnet — Vault V2 + Market Adapter V2 unlock

## Why this matters

The Arc testnet now has Morpho Labs' canonical infrastructure deployed, not just `MorphoBlue` core. The four newly-recorded contracts close the gap between Arc testnet and the Morpho mainnet pattern:

| Contract | Address (Arc 5042002) | Role |
|---|---|---|
| `MorphoChainlinkOracleV2Factory` | `0xEBef760B0CA0d1Fa9578f47001A184Ee53EaE839` | Deploys Chainlink-style price oracles for new Morpho markets. Replaces hand-rolled `MorphoOracleAdapter` for production-pattern markets. |
| `VaultV2Factory` | `0x6b7F638B64539F83810A1f6ea81C703b561C3Be6` | Deploys ERC-4626 MetaMorpho-V2 vaults. Replaces the Arc "DummyVault" testing artifact (`0xAabbeF…`) with a real-pattern vault any integrator can spin up. |
| `MorphoMarketV1AdapterV2Factory` | `0x9372EbEDF2C64344817c67dAeD99512F4b9DC434` | Deploys the V2 adapter that lets a Vault V2 plug into a Morpho V1 (Blue) market. On-chain verified: `morpho() = 0x65f435…` (canonical MorphoBlue). |
| `RegistryList` | `0xcba6be0EF65176CE7D440A4a93657fb2dd84200c` | Curated allowlist of approved market params / curators. Owned by `0xdEaD` (renounced) — read-only directory. |

All four verified live on Arc Testnet on 2026-05-21 (bytecode + linkage probes in `deployments/morpho-arc-testnet.json`).

## What was on Arc before this

- `MorphoBlue` core at `0x65f435eB…` (already known) ✓
- `AdaptiveCurveIrm` at `0xBD583cc9…` ✓
- One **dummy vault** at `0xAabbeF…` with a single Morpho market using OLD FakeCirBTC (`0x44cEe9…`) as collateral and USDC (`0x3600…`) as loan token, 86% LLTV
- Our own self-deployed `MorphoBlue` shadow at `0x3c9b95C6…` — now **deprecated** in favor of the canonical address

## What it unlocks

### 1. Replace the dummy vault with real MetaMorpho-V2 vaults

Today, Arc testnet only has the Morpho Labs DummyVault, which:
- Is single-market (one curated collateral, one curated LLTV)
- Uses OLD FakeCirBTC, not the new issuer-backed cirBTC (`0xf0C4a4CE…`)
- Is not configured like mainnet — Morpho Labs explicitly cautioned against treating it as representative

With `VaultV2Factory` + `MorphoMarketV1AdapterV2Factory`, **Telaraña can deploy its own curated vault on Arc that mirrors the mainnet pattern**:

```
fxTelaranaEurcVault  -> ERC-4626 over USDC
   ├── adapter1: MorphoMarketV1Adapter targeting Morpho market(USDC, EURC, lltv=86%)
   ├── adapter2: MorphoMarketV1Adapter targeting Morpho market(USDC, MXNB-Arc-issuer, lltv=80%)
   ├── adapter3: MorphoMarketV1Adapter targeting Morpho market(USDC, QCAD, lltv=80%)
   └── adapter4: MorphoMarketV1Adapter targeting Morpho market(USDC, cirBTC-issuer, lltv=70%)
```

The vault becomes the rehypothecation target for `FxPrivacyPool` and the loan-side accounting target for the lending UI. Integrators see the standard Morpho-V2 surface (`deposit/withdraw/maxDeposit/etc.`) instead of our bespoke `FxReceipt`.

### 2. Drop the self-deployed Morpho shadow

The SDK had `morphoBlue: 0x3c9b95C6…` for Arc — a contract we deployed ourselves in Stage 6 because Morpho Labs hadn't published a canonical Arc address yet. Now they have.

With this PR, the SDK and `deployments/arc-testnet.json` both point at `0x65f435eB…`. The shadow stays on-chain but is no longer referenced. Any production code that constructs market params now uses the canonical address.

### 3. Real markets for the new tokens (MXNB Arc, QCAD, cirBTC)

The three new Arc tokens added in this PR (MXNB `0x836F73Fb…`, QCAD `0x23d7CFFd…`, real cirBTC `0xf0C4a4CE…`) don't yet have Morpho markets. The new `MorphoChainlinkOracleV2Factory` lets us create market-specific oracles and add markets via `MorphoBlue.createMarket(...)` per the mainnet recipe:

```
1. Deploy MorphoChainlinkOracleV2 for each pair via the factory
   (USDC-loan / MXNB-collateral; USDC-loan / QCAD-collateral; USDC-loan / cirBTC-collateral)
2. MorphoBlue.createMarket(MarketParams{ loanToken: USDC, collateralToken, oracle, irm: AdaptiveCurveIrm, lltv })
3. Wire the market id into FxMarketRegistry (existing surface, no contract change)
4. Wire an adapter into the Telaraña vault from step (1) of "Replace the dummy vault"
```

This is the standard Morpho onboarding recipe — no novel math, vendored oracle/irm/factory contracts, ~50 LOC per market in a deploy script.

### 4. Pre-position for `RegistryList` curation

`RegistryList` is the on-chain curator surface for "approved" market params and risk parameters. Owner is currently `0xdEaD` (renounced), so the registry is immutable. When Morpho Labs ships their curator surface, the entries on this list will be the de-facto trusted market params. By recording the address now, the SDK is ready to read it as a UI-side filter without a contract change.

## Out of scope for this PR

- Deploying the Telaraña Morpho V2 vault. That's a separate workstream (~1-2 day milestone with a deploy script + readiness verifier + SDK wiring).
- Creating Morpho markets for MXNB / QCAD / new cirBTC. Same workstream.
- Migrating `FxMarketRegistry` to point at the new factories. Existing markets keep their current oracle adapters.

## Decision points (for later)

1. **Stay self-deploying oracles vs use `MorphoChainlinkOracleV2Factory`** — the factory produces Chainlink-style oracles (single-feed), while our `MorphoOracleAdapter` wraps multi-source (Pyth + RedStone deviation gate). For the V1 / verified-oracle path we already have, the factory may not give us the same deviation-gate guarantees. Likely keep our adapter for verified-path markets and use the factory only for vanilla Chainlink-equivalent markets.
2. **VaultV2 governance** — who owns the curated Telaraña vault? Options: DEPLOYER_PRIVATE_KEY (current), `FxTimelock`, future multisig. Mirror the Stage-6 pattern: deploy under EOA, hand off to timelock atomically in the same broadcast.
3. **Mainnet recipe parity** — Morpho's mainnet `URDFactory` (universal rewards distributor) is separate from `VaultV2Factory` and not deployed on Arc testnet per Albist's email. We will need to defer Morpho-side reward streaming until mainnet OR self-deploy a URD on Arc if the demo timeline requires it.

## Recorded in

- `deployments/morpho-arc-testnet.json` (full readback + linkage notes, pre-existing)
- `deployments/arc-testnet.json` `external` block (newly added in this PR)
- `packages/sdk/src/addresses/index.ts` `ArcTestnet` entry (newly added: `morphoChainlinkOracleV2Factory`, `morphoVaultV2Factory`, `morphoMarketV1AdapterV2Factory`, `morphoRegistryList`)
- `packages/sdk/src/__tests__/sdk.test.ts` regression assertions for all five Morpho addresses on Arc

## Verification

```bash
# bytecode + linkage probes (re-runnable any time)
cast code --rpc-url $ARC_TESTNET_RPC 0xEBef760B0CA0d1Fa9578f47001A184Ee53EaE839 | wc -c   # 8931 chars
cast code --rpc-url $ARC_TESTNET_RPC 0x6b7F638B64539F83810A1f6ea81C703b561C3Be6 | wc -c   # 46251
cast code --rpc-url $ARC_TESTNET_RPC 0x9372EbEDF2C64344817c67dAeD99512F4b9DC434 | wc -c   # 27269
cast code --rpc-url $ARC_TESTNET_RPC 0xcba6be0EF65176CE7D440A4a93657fb2dd84200c | wc -c   # 2757
cast call --rpc-url $ARC_TESTNET_RPC 0x9372EbEDF2C64344817c67dAeD99512F4b9DC434 'morpho()(address)'
# 0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4 — matches canonical MorphoBlue ✓
```
