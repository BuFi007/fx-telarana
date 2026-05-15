# fx-Telarana — Engineering Spec (v0.3)

**Status**: Direction updated after hook/privacy review
**Date**: 2026-05-15
**Owner**: criptopoeta
**Supersedes**: v0.2 (2026-05-13)

**Locked in v0.3**:
- D1 Lending substrate: **Morpho Blue** isolated markets per pair.
- D2 Compliance model: **Bufi Wallet KYC/KYB pass**. No third-party privacy wallet dependency.
- D3 Oracle: **Pyth primary + RedStone secondary**, both pull-mode.
- D4 Privacy detail: **Ghost Mode routes through privacy hooks and routers**. No Circle Wallet dependency; Circle remains issuer and CCTP infrastructure only.
- D5 Hub liquidity rail: **Circle Gateway is the fast USDC hub-to-hub rail** between Avalanche/Fuji and Arc hubs. Current signing mode is EOA; ERC-1271 contract signing is future-gated.

---

## 1. Product Thesis

Forex Telarana is a cross-chain FX credit hub. Users can enter from supported
chains with USDC or EURC where Circle supports it, route into Avalanche hub FX
markets, and borrow or lend against currency-pair collateral. Circle Gateway
powers fast USDC movement between hubs, Hyperlane powers cross-chain intents
and non-Circle asset routes, CCTP stays Circle-only for canonical USDC and EURC
spoke entry, and the hub risk engine decides what assets are valid collateral.

The product should feel like an onchain FX credit primitive:

> Deposit dollar liquidity, borrow local-currency stablecoins, swap between
> currency rails, and manage collateralized credit with institutional-grade risk
> controls.

There are two UX rails:

| Rail | Trigger | Privacy model | Contract surface |
|---|---|---|---|
| **Public** | Default | Plain wallet/accounting | `FxSpoke`, `FxMarketRegistry`, `FxSwapHook` |
| **Ghost Mode** | User chooses Ghost Mode and Bufi Wallet has a valid KYC/KYB pass | Commitment/nullifier privacy around entry, swap, deposit, and withdrawal flows | Bufi Ghost router + privacy-capable v4 hook/pool wrappers |

Public mode remains permissionless. Ghost Mode is a separate router option and
pool/route family for verified Bufi Wallet users. Do not gate the public pools
with KYC checks.

---

## 2. Ghost Mode Principle

Ghost Mode is not "private by wishful UI." It is a routed execution mode with
three mandatory layers:

1. **Bufi Wallet KYC/KYB pass**: the app verifies that the connected Bufi Wallet
   holds a valid pass. The pass can be an onchain attestation, non-transferable
   token, or signed credential, but the contract-facing verifier must expose a
   small audited interface.
2. **Privacy hook/router**: the Ghost path breaks the direct public link between
   the funding wallet and the action account using commitment/nullifier proofs.
3. **Hub risk engine**: even if the transport is private, the hub still accepts
   only registered chains, assets, routes, market ids, oracle configs, and live
   pools.

The reference KYC hook pattern is useful only as a warning. Do not copy
`tx.origin` based KYC. In Uniswap v4 hooks `msg.sender` is the PoolManager and
the `sender` argument is usually the router. Ghost hooks must authenticate a
trusted Bufi router and verify user/pass data from signed hook data or a
separate verifier call.

The blackbera privacy-hook repo is a concept shell, not production code. Use the
idea, not the implementation.

---

## 3. Wallet And Compliance

Ghost Mode uses **Bufi Wallet**, not Circle Wallet.

Circle remains important for:
- USDC and EURC issuance.
- CCTP V2 burn/mint for USDC and EURC.
- Circle Gateway USDC liquidity movement between hubs.
- Circle Smart Contract Platform monitoring where useful.

Circle is not the Ghost Mode wallet provider, pass issuer, or account factory.

Bufi Wallet requirements:

```solidity
interface IBufiKycPass {
    function hasValidPass(address account) external view returns (bool);
    function passLevel(address account) external view returns (uint8);
}
```

`passLevel` should distinguish at least:
- `1`: KYC individual.
- `2`: KYB entity.

The final pass contract can use a richer schema, but the protocol should depend
only on a tiny verifier interface. Revocation must be fail-closed.

---

## 4. Contracts

All core contracts remain privacy-agnostic where possible. Ghost Mode lives at
the router/hook boundary and in separate privacy wrappers.

### 4.1 Lending Substrate — Morpho Blue

Use Morpho Blue as the lending primitive. Each FX pair is represented as
isolated markets:

| Direction | Loan asset | Collateral asset |
|---|---|---|
| Market A | local stablecoin | USDC or paired stablecoin |
| Market B | USDC or paired stablecoin | local stablecoin |

`FxMarketRegistry` is the single app-facing surface over Morpho:
- `supply`
- `withdraw`
- `supplyCollateral`
- `withdrawCollateral`
- `borrow`
- `repay`

Protected calls still require `onBehalf == msg.sender` unless a future audited
delegation model is added.

### 4.2 `FxSwapHook`

The public swap hook remains the oracle-anchored PMM/re-hypothecation hook for
public pools.

Ghost Mode should use a separate Ghost pool/hook instance, because a Uniswap v4
pool has a single hook address. The Ghost hook family should combine:
- existing `FxSwapHook` pricing/risk invariants,
- trusted Bufi router verification,
- Bufi pass verification,
- commitment/nullifier verification for private entry and withdrawal accounting.

Do not try to stack two independent hooks onto one v4 pool.

### 4.3 `IFxOracle`

`IFxOracle` is the only price-read surface.

```solidity
interface IFxOracle {
    function getMid(address base, address quote) external view returns (uint256 midE18, uint256 publishedAt);
    function getMidWithUpdate(address base, address quote, bytes[] calldata pythUpdate, bytes[] calldata redstoneUpdate)
        external payable returns (uint256 midE18, uint256 publishedAt);
}
```

Ghost hooks must use the same `IFxOracle` path. They must not call Pyth or
RedStone directly.

### 4.4 CCTP Spokes

`FxSpoke` is only for Circle assets:
- USDC
- EURC where Circle supports CCTP for the route

`beneficiary` is always explicit. Public mode can pass the user's normal hub
wallet. Ghost Mode passes the Bufi Ghost router/action account chosen by the
privacy flow. Never derive `beneficiary` from `msg.sender`.

### 4.5 Circle Gateway Hub Liquidity

Circle Gateway is the fast USDC route between Telarana hubs. It is not the
general spoke path and it is not a route for AUDF, JPYC, MXNB, KRW1, ZCHF, or
other non-Circle stablecoins.

Near-term Gateway scope:
- Avalanche Fuji hub ↔ Arc Testnet hub.
- Testnet speaks to testnet at the hub level.
- Source signer is an EOA.
- Future ERC-1271 contract signing is modeled but disabled until Circle support
  is live and the contract signer is allowlisted.

The SDK prepares:
- Gateway Wallet/Minter ABIs.
- Circle EIP-712 BurnIntent types.
- Fuji ↔ Arc route config.
- Gateway hub indexer event names.
- `TelaranaGatewayHubHook` receive-and-route wrapper.

Gateway hook implementations must validate route id, destination Gateway
Minter, destination USDC, caller authorization, received USDC balance delta,
destination hub action, and request replay before using minted funds. The first
implementation stays trusted-executor gated until attestation/hookData context
verification is added.

### 4.6 Hyperlane Asset Spokes

Hyperlane is the non-Circle asset lane. It handles:
- non-Circle asset routing,
- typed cross-chain intent messages,
- optional Interchain Accounts for one-click transfer-and-call flows.

Ghost Mode over Hyperlane must still validate:
- origin domain,
- origin router,
- route id,
- input token,
- destination market,
- nonce/nullifier,
- live pool state.

---

## 5. Ghost Mode Router Stack

Phase 1 uses the Ghost Mode stack below:

| Component | Role |
|---|---|
| `BufiWallet` | User-facing wallet and signer surface. Holds or proves KYC/KYB pass. |
| `IBufiKycPass` verifier | Small contract interface used by Ghost routers/hooks. |
| `FxGhostRouter` | App-facing route planner/executor for Ghost supply, borrow, repay, swap, withdraw, and cross-chain enter. |
| `FxGhostCommitmentRegistry` | Stores Merkle roots and nullifiers for deposits/withdrawals. |
| `FxGhostSwapHook` | Privacy-capable v4 hook instance for Ghost pools. |
| `FxGhostWithdrawalRouter` | Verifies withdrawal proof/nullifier and routes funds to recipient. |

The first implementation may use fixed denomination buckets to improve privacy
sets. Variable amount privacy should wait for audited circuits or a battle-tested
ZK library.

---

## 6. Off-Chain API

Pasillo/API routes:

```text
POST /fx/quote
POST /fx/swap/prepare
POST /fx/lend/prepare
POST /fx/ghost/prepare
POST /fx/ghost/proof
GET  /fx/pools
GET  /fx/positions/:wallet
GET  /fx/eligibility/:wallet
```

`/fx/eligibility/:wallet` returns:

```ts
export enum EligibilityReason {
  OK = "OK",
  NO_BUFI_WALLET = "NO_BUFI_WALLET",
  NO_BUFI_KYC_PASS = "NO_BUFI_KYC_PASS",
  NO_BUFI_KYB_PASS = "NO_BUFI_KYB_PASS",
  KYC_PENDING = "KYC_PENDING",
  KYB_PENDING = "KYB_PENDING",
  PASS_EXPIRED = "PASS_EXPIRED",
  PASS_REVOKED = "PASS_REVOKED",
  COMPLIANCE_BLOCK = "COMPLIANCE_BLOCK",
  GHOST_ROUTE_UNAVAILABLE = "GHOST_ROUTE_UNAVAILABLE",
}
```

Ghost Mode is available only when the Bufi Wallet pass is valid and the target
route/hook exists for the selected action.

---

## 7. Frontend

The app should expose Ghost Mode as a deliberate router option.

Rules:
- Use Bufi Wallet for Ghost Mode.
- Do not require Circle Wallet for Ghost Mode.
- Public mode can still support Dynamic or other EVM wallet connectors if the
  app wants broad access.
- Ghost Mode should clearly show that execution may be slower because proof
  generation, relaying, and nullifier settlement are extra steps.
- The UI must not claim fully private Morpho positions until the hub-side
  accounting is actually shielded. V1 privacy is route/account unlinkability,
  not hidden liquidation state.

Ghost flow:

```text
Bufi Wallet connects
→ pass verifier says KYC/KYB valid
→ user chooses Ghost Mode
→ router prepares commitment/proof/action calldata
→ Ghost hook/router executes deposit, swap, borrow, repay, or withdrawal
→ SDK aggregates public and Ghost-mode positions under one Bufi Wallet view
```

---

## 8. Cross-Chain Flows

### 8.1 Public USDC/EURC Entry

```text
User wallet
→ FxSpoke.enterHub(token, amount, beneficiary, hubCalldata)
→ CCTP V2 burn/mint
→ FxHubMessageReceiver executes hub call
```

### 8.2 Ghost USDC/EURC Entry

```text
Bufi Wallet with valid pass
→ FxGhostRouter prepares commitment and hub action
→ FxSpoke.enterHub(token, amount, ghostBeneficiary, hubCalldata)
→ CCTP V2 burn/mint
→ hub action credits Ghost route/account
→ user later withdraws through proof/nullifier path
```

### 8.3 Ghost Non-Circle Asset Entry

```text
Bufi Wallet with valid pass
→ Hyperlane Warp Route moves asset
→ FxSpokeIntentRouter sends typed intent
→ FxHyperlaneHubReceiver validates route/asset/market
→ Ghost router/hook executes the hub action
```

### 8.4 Ghost Withdrawal

```text
User builds withdrawal proof
→ FxGhostWithdrawalRouter verifies root/nullifier/pass constraints
→ nullifier is marked consumed
→ funds are sent to requested recipient or routed through CCTP/Hyperlane exit
```

---

## 9. Audit Notes

Ghost Mode increases audit scope. Required checks:
- no `tx.origin` authorization,
- trusted router allowlist in hooks,
- no sensitive values stored in hook transient/permanent state,
- nullifier replay protection,
- Merkle root lifecycle and root expiry,
- verifier key governance and timelock,
- rescue path for failed cross-chain execution,
- `IFxOracle` as the only price path,
- `beforeSwapReturnDelta` accounting reviewed independently for every Ghost hook.

Ship order:
1. Public basket markets and swap hooks.
2. Dynamic fee / truncated oracle / TWAMM additions for public hook.
3. Ghost Mode proof-of-concept on Fuji with mocks and low caps.
4. External audit before any production Ghost liquidity.

---

## 10. Open Decisions

- Exact Bufi Wallet pass format: token, attestation, signed credential, or hybrid.
- Whether Ghost pools use fixed amount buckets at v1.
- Whether Ghost withdrawals route directly to a recipient or through a delayed
  withdrawal queue.
- Which ZK verifier/circuit stack is acceptable for production.
- Whether Ghost Mode should require KYC for individuals and KYB for businesses,
  or KYB only for larger limits.
