# Stablecoin Summer Protocol Build Plan

Stablecoin Summer is not a farm.

It is a cross-chain campaign to make stablecoins usable as programmable FX credit.

The initial wedge stays honest:

```text
USDC enters from any supported spoke.
The Fuji/Avalanche hub handles FX markets, lending, collateral, and rewards.
```

The later expansion is Forex perps backed by Morpho FX liquidity, Uniswap v4 execution hooks, and Hyperlane/CCTP cross-chain intents.

This plan is the Codex source of truth for campaign-linked protocol work. Public campaign copy lives in `docs/STABLECOIN_SUMMER_CAMPAIGN.md` and `notion/stablecoin-summer/`.

## Codex Master Context

We are building Forex Telarana / Stablecoin Summer: a cross-chain FX credit protocol.

The current architecture supports USDC-only cross-chain entry from spoke chains into a Fuji/Avalanche hub using CCTP V2. The user chooses whether incoming USDC enters the hub as:

- M1 collateral: USDC collateral against FX stablecoin borrow.
- M2 lend supply: USDC supplied as the loan asset.

Current supported spokes:

- Ethereum Sepolia.
- Arbitrum Sepolia.
- OP Sepolia.
- Polygon Amoy.
- Unichain Sepolia.
- World Chain Sepolia.
- Arc Testnet.
- Fuji self-loop.

The current constraint is important:

```text
Spokes are integrated for cross-chain USDC entry only.
Non-USDC FX assets like AUDF, JPYC, MXNB, KRW1, and ZCHF are not yet live as spoke-origin assets.
```

Near-term model:

1. USDC enters from any supported spoke.
2. USDC lands on the Fuji hub.
3. User routes into hub FX markets.
4. Hub validates market, asset, oracle, and action.
5. Rewards/points are awarded only for completed intents, not raw bridge volume.

Do not pretend multi-asset cross-chain lending is live yet.

We are adding Hyperlane for:

- Cross-chain intent messaging.
- Future non-USDC Warp Routes.
- Remote execution / transfer-and-call style UX.
- Permissionless expansion, with protocol-level asset allowlisting.

The hub must remain the source of truth for:

- AssetRegistry.
- FxMarketRegistry.
- OracleRegistry.
- SpokeRegistry.
- ReceiptTokenRegistry.
- RiskEngine.
- RewardEngine.
- CampaignPointsEngine.

## Campaign

Core campaign:

```text
Stablecoin Summer Genesis
```

Rewarded behaviors:

- Time-weighted USDC supply.
- Healthy FX borrows.
- Cross-chain completed intents.
- Referrals.
- Issuer-prioritized market usage.
- Market diversity.
- Repayment behavior.

Do not reward:

- Raw bridge volume.
- Max leverage.
- Wash deposits.
- Instant deposit/withdraw loops.
- Fake borrow loops.
- Unsafe wrapped assets.

## Future Expansion

Forex perps will be built as a separate clearinghouse/margin engine.

Morpho is the balance sheet / lending layer, not the perp engine.

Uniswap v4 hooks are the FX execution/safety layer, not the full perp engine.

## Track A: Protocol Context Rules

The protocol and frontend language must stay honest:

- Source chain: supported spoke.
- Source asset: USDC only for now.
- Destination hub: Fuji/Avalanche.
- Destination action: deposit collateral, supply lending liquidity, or future borrow setup.
- Result: completed hub position.

Recommended product/domain types:

```typescript
type CrossChainSourceAsset = "USDC";
type DestinationMarketAction = "COLLATERAL" | "SUPPLY" | "BORROW_SETUP";
type SupportedSpokeChain =
  | "ethereum-sepolia"
  | "arbitrum-sepolia"
  | "op-sepolia"
  | "polygon-amoy"
  | "unichain-sepolia"
  | "world-chain-sepolia"
  | "arc-testnet"
  | "fuji";
type HubMarketId = string;
```

Rename or hide any UI/backend/code path that implies non-USDC cross-chain asset support is live.

## Track B: Contracts / Modules To Build First

### P0: Keep USDC Spoke Entry Clean

Task:

- Enforce USDC-only source asset selection on spoke flows.
- Support destination actions: collateral, supply, future borrow setup.
- Surface completed hub position state.
- Emit/read campaign events only after hub action completion.

### P0: Hyperlane Intent Layer

Add a Hyperlane-based intent router layer without replacing the current CCTP V2 USDC movement.

Target files:

```text
contracts/src/spoke/FxSpokeIntentRouter.sol
contracts/src/hub/FxHubIntentReceiver.sol
contracts/src/interfaces/IFxIntent.sol
contracts/src/libraries/FxIntentCodec.sol
```

Intent fields:

- originChainId.
- originDomain.
- sourceSpoke.
- user.
- sourceAsset.
- amount.
- destinationMarketId.
- action.
- recipient.
- nonce.
- deadline.
- referralCode, optional.
- campaignId, optional.

Hub receiver validation:

- Origin spoke is registered.
- Source asset is allowed.
- Destination market exists and is active.
- Action is supported.
- Nonce has not been consumed.
- Deadline has not expired.
- Oracle route exists.
- Risk config exists.

Events:

- CrossChainIntentSent.
- CrossChainIntentReceived.
- CrossChainIntentExecuted.
- CrossChainIntentFailed.

### P0: Registry Hardening

Create or harden:

- AssetRegistry.
- SpokeRegistry.
- FxMarketRegistry.
- OracleRegistry.
- ReceiptTokenRegistry.
- CampaignRegistry.

Every cross-chain action must pass through registry validation.

Hyperlane is permissionless. Protocol collateral acceptance is not.

Per-asset allowlist config:

- canonicalAssetSymbol.
- localToken.
- acceptedRoute.
- acceptedSynthetic.
- oracleId.
- maxLTV.
- liquidationThreshold.
- collateralFactor.
- isCollateralEnabled.
- isBorrowEnabled.
- isSupplyEnabled.

## Track C: Stablecoin Summer Rewards Engine

Build a flexible points/rewards engine for:

- USDC cashback.
- Borrow-rate rebates.
- Issuer-funded rewards.
- Fee rebates.
- Campaign points.
- Referrals.

Target modules:

- CampaignRegistry.
- CampaignPointsEngine.
- RewardEligibilityEngine.
- ReferralAttributionRegistry.

Rewardable actions:

- USDC_SUPPLY.
- USDC_COLLATERAL_DEPOSIT.
- FX_BORROW.
- HEALTHY_POSITION_DURATION.
- CROSS_CHAIN_INTENT_COMPLETED.
- REFERRAL_ACTIVATED.
- MARKET_DIVERSITY_BONUS.
- ISSUER_MARKET_BONUS.

Never reward raw bridge volume.

Eligibility rules:

- Minimum deposit amount.
- Minimum borrow amount.
- Minimum duration.
- Max LTV threshold.
- No liquidation.
- Market active.
- Oracle healthy.
- No same-block deposit/withdraw farming.

Track:

- user.
- campaignId.
- marketId.
- actionType.
- amount.
- timeWeightedAmount.
- sourceChain.
- referralCode.
- points.
- rewardToken.
- claimedAmount.

Genesis reward buckets:

```text
40% USDC suppliers
30% FX borrowers
20% cross-chain completed intents
10% referrals / quests / community
```

Initial target markets:

- USDC collateral / JPYC borrow.
- USDC collateral / MXNB borrow.
- USDC collateral / AUDF borrow.
- USDC collateral / ZCHF borrow.
- USDC collateral / KRW1 borrow.

EURC is disabled/TBD.

BRLA and PHPC are excluded for now.

## Track D: Notion Public Campaign Docs

Local Markdown source:

```text
notion/stablecoin-summer/index.md
notion/stablecoin-summer/rewards.md
notion/stablecoin-summer/markets.md
notion/stablecoin-summer/issuers.md
notion/stablecoin-summer/builders.md
notion/stablecoin-summer/perps-next.md
```

Publish with `ntn pages create < file.md`, or update existing page IDs once created.

## Track E: Forex Perps Roadmap

Do this later, not now.

Perps v1:

- USDC margin only.
- USDC-settled PnL.
- 2-3 pairs max.
- Pyth primary.
- RedStone fallback.
- Uniswap v4 TWAP sanity check.
- Insurance fund.
- Liquidation bot.
- Open interest caps.
- Funding engine.

Future contracts:

- FxPerpClearinghouse.sol.
- FxPerpMarket.sol.
- FxFundingEngine.sol.
- FxInsuranceFund.sol.
- FxOracleRouter.sol.
- FxLiquidationEngine.sol.
- FxV4Hook.sol.
- MorphoLiquidityAdapter.sol.

V1 pairs:

- USD/JPY.
- USD/MXN.
- USD/CHF.

Later:

- AUD/USD.
- USD/KRW.
- EUR/USD if EURC becomes available.

## Execution Order

### Week 1: Stablecoin Summer Source Of Truth

- Add `docs/protocol/STABLECOIN_SUMMER.md`.
- Add Notion campaign docs.
- Update frontend copy to say USDC cross-chain entry, not multi-asset cross-chain lending.
- Add CampaignRegistry interfaces.
- Add campaign constants and market IDs.

### Week 2: Hyperlane Intent Router

- Build FxSpokeIntentRouter.
- Build FxHubIntentReceiver.
- Add intent encoding/decoding.
- Add nonce/deadline protection.
- Add registry validation.
- Emit campaign-readable events.

### Week 3: Rewards Engine

- Add CampaignPointsEngine.
- Add RewardEligibilityEngine.
- Track time-weighted supply.
- Track healthy borrow duration.
- Track completed cross-chain intents.
- Track referral attribution.

### Week 4: Market Expansion

- Deploy mock AUDF.
- Deploy mock JPYC.
- Deploy mock MXNB.
- Deploy mock KRW1.
- Deploy mock ZCHF.
- Add receipt tokens if needed.
- Add oracle configs.
- Add registry entries.
- Add manifest IDs.

### Week 5+: Perps Design Branch

- Start `research/fx-perps-clearinghouse`.
- Build only USDC-settled mock perp engine.
- Use oracle-only mark price first.
- Add v4 TWAP sanity later.
- Add Morpho liquidity adapter after clearinghouse works.

## Suggested Branch Structure

```bash
git checkout -b codex/docs-stablecoin-summer-campaign
git checkout -b codex/feature-hyperlane-intent-router
git checkout -b codex/feature-campaign-points-engine
git checkout -b codex/feature-fx-market-registry-hardening
git checkout -b codex/feature-mock-fx-assets
git checkout -b codex/research-fx-perps-clearinghouse
```

## README One-Liner

Stablecoin Summer is a cross-chain FX credit campaign: users enter from supported chains with USDC, route into hub-based currency markets, earn real stablecoin yield and rewards, and eventually access Forex perps backed by Morpho liquidity and Uniswap v4 execution.

## Discipline

Campaign now, perps next.

Stablecoin Summer should prove the first flywheel:

```text
USDC deposits
-> FX borrow demand
-> higher utilization
-> stronger supplier yield
-> issuer campaigns
-> more currency markets
-> more cross-chain entrants
```

Then Forex perps become the volume engine on top.
