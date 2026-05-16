```text
You are starting a new Next Forge backend worktree for the FX Telaraña
LOAN & BORROW backend. This is the dedicated lending-protocol backend —
NOT the swap hook, NOT perps, NOT FX Bento arcade. Those each get their
own worktree later.

Worktree:  feature/next-forge-fx-telarana-loan-borrow
Repo:      monorepo root (same checkout as the existing fx-telarana
           contracts package).
Reference: the existing prompt at .context/attachments/pasted_text_2026-05-16_09-53-24.txt
           defines the broader monorepo conventions (Next Forge, Bun,
           Hono, Ponder, Liveblocks, MCP, x402, no Clerk). This prompt
           scopes the WORK to lending-and-borrowing.

Use the /next-forge workflow and conventions.

Use these skills when relevant:
  /next-forge                        scaffold + structure
  /v4-sdk-integration                contract-side typed surface
  /viem-integration                  reads/writes
  /codex:adversarial-review          before merge
  /gateman-analysis                  post-implementation audit
  /codex-adversarial-tenderly-auditor  live testnet pass

────────────────────────────────────────────────────────────────────────
PRODUCT FRAMING
────────────────────────────────────────────────────────────────────────

FX Telaraña is a stablecoin-FX lending/borrowing protocol built on top
of audited Morpho Blue isolated markets. It supports stablecoin FX pairs:

  USDC ↔ EURC      USDC ↔ JPYC     USDC ↔ MXNB
  USDC ↔ BRL       USDC ↔ QCAD     ...

At the contract layer, every pair is TWO Morpho Blue isolated markets:

  M1: loanToken = TOKENA, collateralToken = TOKENB
  M2: loanToken = TOKENB, collateralToken = TOKENA

A lender deposits the loan asset of one market. A borrower deposits the
collateral asset of the matching market and then borrows.

This backend exposes:
  • Public read API for markets, positions, rates, TVL.
  • Quote API for supply/borrow/repay/withdraw (margin previews,
    liquidation prices, max-borrow, post-trade health factor).
  • EIP-712 signed-intent flows for cross-chain operations
    (a user on Optimism Sepolia signs a "supply collateral + borrow"
    intent that the hub on Avalanche Fuji or Arc executes).
  • Ponder-indexed positions/events.
  • Liquidation candidate discovery for keepers.
  • DefiLlama TVL adapter (publishes per-market TVL in their format).
  • MCP tools for AI-agent inspection (read-only by default; signed
    actions require explicit wallet signature, never auto-executed).
  • x402-gated premium endpoints (historical APY, liquidation density,
    on-demand quote-with-simulation).

────────────────────────────────────────────────────────────────────────
WHAT'S ALREADY ONCHAIN  —  TREAT AS THE GROUND TRUTH
────────────────────────────────────────────────────────────────────────

Solidity contracts (under contracts/src/, branch tcxcx/pasted-text-task):

  contracts/src/hub/FxMarketRegistry.sol
    • Single surface over Morpho Blue isolated markets per pair.
    • Public functions: supply, withdraw, borrow, borrowDelegated, repay,
      supplyCollateral, withdrawCollateral.
    • AccessControl: DEFAULT_ADMIN_ROLE (timelock) + OPERATIONS_ROLE.
    • Pausable: pause halts entry-side; exit-side always works.
    • Per-pair live toggle: setPoolLive(loan, collateral, bool).
    • Borrow-delegate registry: setBorrowDelegate(delegate, allowed) — for
      cross-chain intent receivers and trusted relayers.
    • listPools() enumerates every registered market for indexers.

  contracts/src/hub/FxLiquidator.sol
    • Permissionless keeper wrapper around IMorpho.liquidate.
    • Bundles fresh Pyth (and Phase 0.5: RedStone) payloads so oracle is
      fresh in the same tx as the liquidation.
    • Pausable via OPERATIONS_ROLE.

  contracts/src/hub/FxOracle.sol
    • Sole price-read surface in Solidity. NEVER bypass to read Pyth or
      RedStone directly. Backend TypeScript MUST also call FxOracle, not
      Pyth's HTTP API, when a price feeds into a financial calculation.

  contracts/src/hub/MorphoOracleAdapter.sol
    • IFxOracle → Morpho's IOracle adapter, deployed per market.

  contracts/src/hub/FxReceipt.sol
    • Lender share + receipts (for tokenizing lend positions).

  contracts/src/hub/FxHubMessageReceiver.sol
    • CCTP V2 inbound + Stage 6 cross-hub Gateway relay.
    • Surface: executeDeposit(payload, sig), sweepStrandedDeposit(nonce),
      relayMintFromRemote(payload, sig), relayToRemoteHub(...).

  contracts/src/spoke/FxSpoke.sol
  contracts/src/spoke/FxSpokeIntentRouter.sol
    • Per-chain CCTP V2 deposit entrypoint. enterHub(token, amount,
      beneficiary, hubCalldata) explicit-beneficiary signature.

  contracts/src/hub/FxRouter.sol
  contracts/src/libraries/FxRouterLib.sol
    • Phase 2.6R routing layer for cross-chain intents.

  contracts/src/hub/FxHyperlaneHubReceiver.sol
  contracts/src/libraries/FxHyperlaneIntentLib.sol
    • Hyperlane intent receipt + decoding.

  contracts/src/ghost/{FxGhostCommitmentRegistry,FxGhostKycHook,FxGhostSpokeRouter}.sol
    • Ghost-mode privacy routing (Bufi Ghost). Beneficiary != msg.sender.

  contracts/src/governance/FxTimelock.sol
    • Owner role for hub-level admin actions.

Deployment manifests live under deployments/:

  deployments/avalanche-fuji.json        — PRIMARY HUB
  deployments/arc-testnet.json           — TRADING-EXECUTION HUB
  deployments/hub-config-fuji.json       — Fuji hub-level params
  deployments/hub-config-arc.json        — Arc hub-level params
  deployments/ethereum-sepolia.json      — Spoke
  deployments/op-sepolia.json            — Spoke
  deployments/arbitrum-sepolia.json      — Spoke
  deployments/polygon-amoy.json          — Spoke
  deployments/unichain-sepolia.json      — Spoke
  deployments/worldchain-sepolia.json    — Spoke
  deployments/base-sepolia.json          — Retired hub (no spokes route here)
  deployments/tenderly-base-sepolia.json — Tenderly vnet snapshot
  deployments/hyperlane-arc-testnet.json — Hyperlane mailbox/IGP

Read these via the existing SDK address tables — DO NOT hardcode:

  packages/sdk/src/addresses/index.ts    — FxAddresses per chain
  packages/sdk/src/telarana-client.ts    — Telarana.route() spoke registry

The SDK's `FxAddresses` interface already exposes:
  fxMarketRegistry, fxLiquidator, fxOracle, fxReceipt, fxHubReceiver,
  fxGatewayHook, fxSpoke, fxSpokeAlt, morpho, fxTimelock, …

NB: `packages/sdk/src/abis/FxSwapHook.ts` is STALE for Phase 2.7 swap
hook changes. That's a separate handoff (HANDOFF.md). The loan/borrow
ABIs (`FxMarketRegistry`, `FxLiquidator`) are current at the time of
this prompt — verify with `bun run sdk:test` before relying on them.

────────────────────────────────────────────────────────────────────────
WHAT THIS BACKEND OWNS
────────────────────────────────────────────────────────────────────────

apps/api  (Hono + Next Forge route conventions, or whatever the existing
          monorepo uses — DO NOT invent a new framework)
apps/web  (Next.js, lending UI scaffolds + integrator routes)

packages/fx-telarana
  • Domain logic for lending:
      - market registry view layer (read from FxMarketRegistry.listPools
        on each hub, cache, expose by pair)
      - position view layer (read Morpho.position + market.totalSupply
        + totalBorrow; combine with oracle for health factor)
      - quote engine for supply/borrow/repay/withdraw (uses Morpho's
        IRM read + FxOracle for HF math)
      - intent builder (EIP-712 typed-data for cross-chain ops)
      - liquidation candidate scanner (scrolls positions, computes HF,
        ranks by closest-to-LLTV; powered by Ponder index, not full
        on-chain enumeration)
  • Pure TS, framework-agnostic, used by apps/api and apps/web.

packages/ponder  (extend existing — don't fork)
  • Add handlers for:
      Morpho events:
        Supply, Withdraw, Borrow, Repay,
        SupplyCollateral, WithdrawCollateral, Liquidate
      FxMarketRegistry events:
        MarketRegistered, PoolLiveSet, BorrowDelegateSet
      FxLiquidator events:
        Liquidated (downstream of Morpho.Liquidate)
  • Schema entities:
      Market { id, loanToken, collateralToken, oracle, irm, lltv,
        isLive, totalSupplyAssets, totalBorrowAssets, …, hubChainId }
      Position { id (= market||account), market, account, supplyShares,
        borrowShares, collateral, healthFactor (computed at index time
        with oracle snapshot), lastUpdated }
      LendingEvent { id, type, market, account, assets, shares,
        txHash, block, ts }
      OracleSnapshot { id, market, midE18, ts, pythSequence,
        redstoneSig }
  • RPC: read from `MARKET_DATA_RPC_URL` (typed env). Hubs are Fuji and
    Arc. Spokes don't have lending events; ignore them here.

packages/liveblocks  (reuse Sendero patterns)
  • Lending room type: `fx-telarana:{hubChainId}:{marketId}`
  • Used for presence on the borrow/supply page, hover preview of a
    position, live position list. Liveblocks IS NOT the source of truth
    for any balance or position — Ponder + on-chain reads are.

packages/contracts  (reuse Sendero's typed contracts package pattern)
  • Re-export the SDK's typed clients for FxMarketRegistry, FxLiquidator,
    FxOracle, Morpho, FxReceipt. Use viem for reads/writes.

packages/mcp  (reuse Sendero's MCP package; extend it)
  • New tools (read-only by default):
      inspect_fx_telarana_market(loanToken, collateralToken, hubChainId)
      inspect_fx_telarana_position(address, marketId)
      quote_fx_telarana_supply(market, amount)
      quote_fx_telarana_borrow(market, collateral, borrowAmount, account)
      list_fx_telarana_liquidation_candidates(market, limit)
      inspect_fx_telarana_oracle_freshness(market)
      inspect_fx_telarana_tvl(byMarket | byHub | total)
  • Signed-action tools (NEVER auto-executed; always require wallet sig):
      build_supply_intent          → EIP-712 payload + chainId + verifyingContract
      build_borrow_intent          → ditto
      build_repay_intent           → ditto
      build_withdraw_intent        → ditto
      build_supplyCollateral_intent
      build_withdrawCollateral_intent
  • The "build" tools return UNSIGNED EIP-712 payloads. The user signs
    in their own wallet. The backend NEVER holds a user private key.

packages/x402  (reuse Sendero's middleware; extend it)
  • Gate these as paid:
      GET /fx-telarana/markets/:id/historical-apy?range=...
      GET /fx-telarana/liquidations/density
      POST /fx-telarana/quote/borrow-with-sim
        (paid if the request asks for a Tenderly transactions-RPC
        simulation in addition to the cheap on-chain read quote)
      MCP tool execution that consumes provider quota

packages/defillama
  • NEW package. DefiLlama TVL adapter implementation, plus the
    in-repo TVL aggregator that backs /fx-telarana/tvl.
  • Reference: https://github.com/DefiLlama/DefiLlama-Adapters
  • Adapter must export the protocol's TVL per chain in their canonical
    format:
        async function tvl(api) {
          // sum (totalSupplyAssets − totalBorrowAssets) across all
          // FxMarketRegistry-registered markets on that chain
          // value in USD via FxOracle reads only
        }
  • Cross-check ABI: Morpho's IMorpho.market(id) → Market struct with
    totalSupplyAssets / totalBorrowAssets / totalSupplyShares / etc.
  • TVL definition (write this in the package README, will need to
    re-verify against DefiLlama's listing rules):
       TVL_market = totalSupplyAssets_in_USD
       BorrowedUSD = totalBorrowAssets_in_USD
       NetSupply  = TVL_market − BorrowedUSD
    DefiLlama distinguishes "TVL" (= net supply) from "Borrowed". Both
    must be reported per the lending-protocol adapter convention.
  • Submit the adapter to DefiLlama-Adapters via PR ONLY AFTER mainnet
    deploy. Testnet TVL stays internal (apps/api/routes/fx-telarana/tvl).

────────────────────────────────────────────────────────────────────────
API ROUTES
────────────────────────────────────────────────────────────────────────

Mirror the conventions in pasted_text_2026-05-16_09-53-24.txt. Specific
to loan/borrow:

  GET  /health
  GET  /liveblocks/auth                            (reuses existing handler)

  GET  /fx-telarana/markets                        list of (loan, coll, hub)
  GET  /fx-telarana/markets/:hubChainId/:marketId  one market detail
  GET  /fx-telarana/markets/:hubChainId/:marketId/state   supply/borrow/util
  GET  /fx-telarana/markets/:hubChainId/:marketId/apy      live APY
  GET  /fx-telarana/markets/:hubChainId/:marketId/historical-apy  X402
  GET  /fx-telarana/markets/:hubChainId/:marketId/oracle   freshness
  GET  /fx-telarana/positions/:address             across all markets
  GET  /fx-telarana/positions/:address/:marketId   single position + HF

  POST /fx-telarana/supply/quote                   zod-validated
  POST /fx-telarana/supply/intents                 EIP-712, no sig yet
  GET  /fx-telarana/supply/intents/:id             intent state

  POST /fx-telarana/borrow/quote
  POST /fx-telarana/borrow/intents
  GET  /fx-telarana/borrow/intents/:id

  POST /fx-telarana/repay/quote
  POST /fx-telarana/repay/intents

  POST /fx-telarana/withdraw/quote
  POST /fx-telarana/withdraw/intents

  POST /fx-telarana/collateral/supply/intents
  POST /fx-telarana/collateral/withdraw/intents

  GET  /fx-telarana/liquidations/candidates        (optionally paginated)
  GET  /fx-telarana/liquidations/density           X402

  GET  /fx-telarana/tvl                            (cached, public)
  GET  /fx-telarana/tvl/by-market
  GET  /fx-telarana/tvl/by-hub
  GET  /fx-telarana/tvl/defillama                  exact DefiLlama-adapter
                                                   compatible payload

────────────────────────────────────────────────────────────────────────
EIP-712 INTENTS
────────────────────────────────────────────────────────────────────────

Use the same domain separator pattern as gateway-signer
(packages/sdk/scripts/gateway-signer.ts) so the cross-chain plumbing
is consistent.

Suggested intent types:

  FxTelaranaSupplyIntent {
    chainId,         // hub chainId (Fuji 43113 or Arc 5042002)
    spokeChainId,    // origin chain
    loanToken,
    collateralToken,
    assets,          // raw decimals
    onBehalf,        // beneficiary on the hub
    nonce,
    deadline         // unix seconds, bounded ≤ 1h ahead per per-domain
                     // block-window convention used by gateway-signer
  }

  FxTelaranaBorrowIntent {
    chainId,
    spokeChainId,
    loanToken,
    collateralToken,
    borrowAssets,
    receiver,        // where borrowed assets land
    onBehalf,
    nonce,
    deadline
  }

  ditto for Repay, Withdraw, SupplyCollateral, WithdrawCollateral.

All deadlines are HARD-CAPPED at ≤ 7200 blocks-equivalent (mirrors the
MAX_BLOCK_WINDOW guard in gateway-signer.ts). Reject anything larger
with a clear error.

────────────────────────────────────────────────────────────────────────
PRICING / HEALTH FACTOR
────────────────────────────────────────────────────────────────────────

ALL price reads in the backend must go through FxOracle.getMid(token0,
token1) on the relevant hub chain. NEVER hit Pyth's HTTP API or
RedStone's REST endpoint directly. This is the same rule as
Solidity-side and is critical for incident-response consistency.

Health factor formula (verify against Morpho's MarketLib once during
implementation; do not invent):

  collateralValueE18 = collateral * collateralPriceE36 / 1e36
  borrowValueE18     = totalBorrowAssets_user (Morpho.expectedBorrowAssets)
  HF                 = collateralValueE18 * lltv / borrowValueE18 / 1e18
  liquidatable       = HF < 1e18

Morpho's existing libraries:
  morpho-blue/libraries/MarketParamsLib
  morpho-blue/libraries/periphery/MorphoBalancesLib

Use TypeScript ports of these (Morpho ships them as @morpho-org/blue-sdk
on npm; vendor cleanly via packages/contracts if the npm package isn't
already a dep).

────────────────────────────────────────────────────────────────────────
DEFILLAMA TVL — SPECIFIC INSTRUCTIONS
────────────────────────────────────────────────────────────────────────

DefiLlama's adapter standard:
  https://github.com/DefiLlama/DefiLlama-Adapters/blob/main/README.md

Required exports for a lending-protocol adapter:

  module.exports = {
    methodology: "<one-line description>",
    misrepresentedTokens: false,
    avalanche: { tvl, borrowed },
    arc:       { tvl, borrowed },
    // additional chains as protocol expands
  };

Where:
  tvl(api)      → sums totalSupplyAssets across all FxMarketRegistry
                  markets on that chain, priced in USD via FxOracle.
                  Returns balances object: { [tokenAddress]: amount }
                  in token native decimals — DefiLlama prices them.
  borrowed(api) → sums totalBorrowAssets across all markets, same
                  shape.

The adapter file (`packages/defillama/src/adapter.ts`) must run with
node + viem against public RPC endpoints (DefiLlama runs adapters from
their CI without our infra). DefiLlama's `api.add(token, amount)` helper
is documented in their repo; use it instead of building our own balance
map.

In-repo TVL endpoint (/fx-telarana/tvl/defillama):
  • Same math as the adapter, but executed against our cached Ponder
    state for speed.
  • Returns the adapter-compatible payload so we can dogfood the format
    before submitting.

Testnet → DO NOT submit the adapter to DefiLlama. Run it internally for
verification only. Mainnet → submit a PR per their contribution guide.

────────────────────────────────────────────────────────────────────────
SECURITY RULES  —  HARD, NON-NEGOTIABLE
────────────────────────────────────────────────────────────────────────

  • No Clerk. No SaaS auth boilerplate.
  • Wallet/session auth + EIP-712 for any state-changing endpoint.
  • All inputs zod-validated.
  • All signatures verified server-side.
  • Nonces strictly enforced (per-user counter; check + increment in DB).
  • Deadlines strictly enforced; cap at 7200 blocks per-domain equiv.
  • Oracle freshness checked before quoting. If FxOracle.getMid reverts
    Stale, return 503 + retry-after.
  • Ponder index state RECONCILED with a fresh on-chain read for any
    critical action (esp. liquidation candidate confirmation).
  • x402 paid actions must verify the payment receipt server-side
    before executing. Receipts logged.
  • MCP tools NEVER move money. They produce unsigned payloads. User
    signs in their own wallet.
  • No private keys in code. Typed env only (zod-validated env package).
  • Structured logs (pino or whatever the existing logger uses).
  • Pre-1271 EOA authority phase: until mid-July 2026 the deployer EOA
    `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` signs all BurnIntents
    off-chain. The backend MUST honor the gateway-signer.ts conventions:
    GATEWAY_SIGNER_BLOCK_WINDOW cap, GATEWAY_SIGNER_ALLOW_BYPASS gate.

────────────────────────────────────────────────────────────────────────
CIRCLE GATEWAY + CCTP V2 INTEGRATION (CONTEXT YOU INHERIT)
────────────────────────────────────────────────────────────────────────

A cross-chain supply flow looks like:

  1. User on Optimism Sepolia signs an EIP-712 FxTelaranaSupplyIntent
     against the Fuji hub (chainId 43113).
  2. Spoke router (FxSpoke) burns USDC on OP Sepolia via CCTP V2,
     attaching enterHub(token, amount, beneficiary, hubCalldata) where
     hubCalldata encodes a supplyCollateral or supply call on
     FxMarketRegistry on Fuji.
  3. CCTP V2 attests; FxHubMessageReceiver.executeDeposit on Fuji
     mints USDC and forwards into FxMarketRegistry via the borrow
     delegate.
  4. Position appears for `onBehalf` (the user's address).
  5. Optionally, the user signs a follow-up FxTelaranaBorrowIntent
     to draw stablecoin against the just-supplied collateral. Borrow
     proceeds can be CCTP'd back to any chain via Circle Gateway
     (FxGatewayHook).

For Fuji ↔ Arc the cross-hub USDC liquidity rail is Circle Gateway,
NOT CCTP V2 (lower latency, ~349ms). See docs/BUFX_INTEGRATION.md and
docs/GATEWAY_E2E.md.

The backend's job is to:
  • Produce the right EIP-712 payload for each step.
  • Verify the user signature.
  • Submit attestation-bound transactions where needed (the backend can
    be the relayer, but should be auditable; pre-1271 the deployer EOA
    is the signer).
  • Surface progress (Ponder events) back to the UI in realtime
    (Liveblocks for presence, REST for state).

────────────────────────────────────────────────────────────────────────
LICENSING
────────────────────────────────────────────────────────────────────────

Per CLAUDE.md and the project's licensing split:

  contracts (Solidity):              Apache-2.0 (unchanged)
  packages/sdk, packages/contracts:  Apache-2.0
  apps/api, apps/web/api routes,
    packages/ponder, packages/mcp,
    packages/x402, packages/defillama,
    packages/fx-telarana
    (everything backend/api/indexer/
    agent/workflow):                 AGPL-3.0-only
  packages/ui, apps/web frontend:    MIT

Add SPDX headers on EVERY new source file.

────────────────────────────────────────────────────────────────────────
DELIVERY PLAN — DO NOT START CODING UNTIL THESE STEPS ARE DONE
────────────────────────────────────────────────────────────────────────

1. Inspect existing monorepo.
   • Package manager? scripts? Next Forge or vanilla Turborepo?
   • Where is the Sendero Liveblocks integration? Read it end-to-end.
   • Where is the Sendero Ponder setup? Read its schema + indexer.
   • Existing env validation pattern?
   • Existing logger?
   • Existing FxAddresses SDK location?
   • Existing apps/web / apps/api layout?

2. Produce a written gap list. What exists, what doesn't, what to reuse.

3. Decide vs document:
   • Which Ponder instance covers Fuji vs Arc? Are they separate
     deployments or one multi-network Ponder app?
   • Do we add a viem chain config for both hubs upfront, or only Fuji
     (P0) and Arc later (P1)?
   • Where do EIP-712 type definitions live so contracts/, sdk/, and the
     backend share them? (A shared types package, ideally.)

4. Implementation plan (steps 1-8 in pasted_text_..._09-53-24.txt §
   "Worktree instructions"). Mirror that structure.

5. Implement in order:
   a) packages/fx-telarana with market + position views, quote engine.
   b) packages/ponder additions (events + schema).
   c) apps/api routes hooked up to (a) and (b).
   d) packages/mcp tool registry extension (read-only first).
   e) packages/defillama adapter + in-repo TVL endpoint.
   f) packages/x402 gating on the premium endpoints.
   g) packages/liveblocks lending-room metadata.
   h) apps/web scaffolds (market list, position panel placeholders).
   i) Tests.

6. Run typecheck. Run tests. Run lint.

7. Open a draft PR. List changed files. Reference HANDOFF.md for the
   swap-hook side of the world so reviewers know not to expect
   PMM-curve work in this branch.

────────────────────────────────────────────────────────────────────────
TESTS
────────────────────────────────────────────────────────────────────────

  • zod validators (happy + sad path on every route).
  • EIP-712 signature verification helpers.
  • Quote engine round-trip vs Morpho.expectedSupplyAssets /
    expectedBorrowAssets / expectedBorrowAssetsAfter etc. (use
    Morpho's TS SDK or vendor the math).
  • Health factor calculation against fixtures.
  • Liquidation candidate scanner: given a fixture of positions, returns
    them sorted by HF ascending.
  • DefiLlama adapter against a snapshot vnet: deploy a fresh Morpho
    market, supply X, borrow Y, snapshot, run adapter, assert balances
    map shape.
  • x402 middleware accepts valid receipts, rejects invalid.
  • MCP tool registry: inspect tools and verify the signed-action ones
    return unsigned payloads only.

────────────────────────────────────────────────────────────────────────
FINAL RULES
────────────────────────────────────────────────────────────────────────

• Liveblocks makes it realtime.
• Ponder makes it indexed.
• x402 makes paid AI/API actions economically gated.
• MCP makes workflows agent-operable.
• DefiLlama makes our TVL public/comparable.
• Contracts settle money.
• The backend coordinates — but never moves money without a user
  signature.
• No Clerk. No SaaS starter boilerplate.
• No novel math in production. Vendor from an audited reference. If
  Morpho's TS SDK doesn't expose the helper you need, vendor THEIR
  Solidity math into a documented TypeScript port — never re-derive.
• Use /next-forge.
```
