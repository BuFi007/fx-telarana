# Hyperlane → Production + Protocol Integration

**Scope (decided 2026-06-03):** FULL — warp-route token bridging **and** cross-chain
FX/perp/ghost message integration. **Prove to production grade on Fuji ↔ Arc-testnet
first**, then lift the exact same shape to mainnet (Avalanche C-Chain first; Arc mainnet
when Circle opens it — no public Arc-mainnet RPC today).

**Why Hyperlane:** CCTP + Circle Gateway already move USDC. Hyperlane is the rail for
everything USDC can't — bridging the non-USDC stables (JPYC / MXNB / AUDF / QCAD / cirBTC)
and carrying FX intent + perp settlement + ghost messages cross-chain. This is what makes
us a true multi-currency FX protocol instead of USDC-only.

## Current state (grounded)
- Core deployed both sides (2026-05-15). Arc Mailbox `0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9`.
- Lane smoke-tested: Fuji→Arc full relay PASS (`messageId 0xb598…52ca`); Arc→Fuji dispatch-only.
- Security = `trustedRelayerIsm` (deployer EOA) on both sides. NOT trust-minimized.
- `interchainGasPaymaster = 0x000…0` — no IGP; relayer hand-funded.
- Warp routes: YAMLs authored (`hyperlane/warp-routes/*.yaml`) but **NOT deployed** —
  `HypERC20Collateral`/`HypERC20` missing → no token bridges yet (`hyperlane-mxnb-fuji-arc.json` = blocker).
- Spoke message contracts exist (`contracts/src/spoke/*`, `hub/FxHubMessageReceiver.sol`)
  but the live money path is CCTP/Gateway, not Hyperlane.

---

## Phase 1 — Trust-minimized security (replace the trusted relayer)
The lane is a "trust-me" bridge today. No value crosses until this lands.

1. **Validators** — run ≥1 validator per origin chain (Fuji, Arc-testnet). Keys in AWS KMS,
   never env. Each signs the Mailbox merkle root and announces via `validatorAnnounce`
   (`0xbBc9AE…3062` on Arc).
2. **MultisigISM** — deploy a MessageId multisig ISM per destination with our validator set;
   author `hyperlane/{fuji,arc-testnet}/multisig-ism.yaml`, deploy with
   `npx @hyperlane-xyz/cli ism deploy`, retire the trusted-relayer ISM on every recipient.
3. **Relayer** — run a relayer agent (delivers + submits signatures). Host on Railway/Fly
   alongside the existing services; alerting on balance + undelivered queue.
4. **IGP** — deploy + wire an InterchainGasPaymaster so senders pay destination gas
   (Arc gas is 18-dec native USDC; Fuji is AVAX). Today the relayer eats every delivery.

**Acceptance:** a message from Fuji→Arc verifies through the multisig ISM (not trusted
relayer), gas paid via IGP, relayer + validator running as monitored services.

## Phase 2 — Warp routes (token bridging — configs already authored)
Deploy the existing `hyperlane/warp-routes/*.yaml`. Per token: `HypERC20Collateral` on the
home chain (locks the real token) + `HypERC20` synthetic on the spoke, cross-enrolled, behind
the Phase-1 multisig ISM.

- `npx @hyperlane-xyz/cli warp deploy --config hyperlane/warp-routes/<TOKEN>.yaml` for
  **JPYC, MXNB, AUDF, QCAD, cirBTC**. (EURC is Circle-native both sides — confirm whether it
  needs a warp route or stays native; no YAML today.)
- Set warp-route **rate limits** + verify the ISM wiring.
- Record deployed collateral/synthetic addresses back into `deployments/hyperlane-*-fuji-arc.json`
  (flip status from `blocker` → `live`).
- Smoke: bridge 1.0 of each token Fuji→Arc and back; assert mint/burn + balances on both sides.

**Acceptance:** each non-USDC stable round-trips Fuji↔Arc over Hyperlane with real
collateral lock + synthetic mint, verified on-chain.

## Phase 3 — Wire into the protocol (the real engineering)
Make Hyperlane a first-class rail in the hub/spoke FX engine, not a side demo.

- **FX intents:** route cross-chain swap/quote intents over `Mailbox.dispatch` →
  `FxHubMessageReceiver.handle()` / `FxSpokeIntentRouter`. The lane is already proven for
  message passing.
- **Perp settlement:** carry settlement/funding messages cross-chain to the perp stack
  (`FxOrderSettlement` etc.) where the counterparty chain differs.
- **Ghost:** `FxGhostSpokeRouter` — shielded intents over Hyperlane (compose with the
  existing relayer + dark=ghost rule; never downgrade to public).
- **Gateway proof mode:** TGH already supports `SIGNED_INTENT_OR_HYPERLANE` — promote
  Hyperlane to a first-class settlement proof, not just an option.
- **Aggregator:** let Pasillo treat a Hyperlane warp hop as a routable leg for non-USDC
  corridors (e.g. JPYC on chain A → MXNB on chain B).

**Acceptance:** an end-to-end cross-chain FX intent (and one ghost intent) settles over
Hyperlane through the multisig ISM, exercised from the app/MCP.

## Phase 4 — Audit + ops + registry (before any value)
- **Security audit** of warp routes + multisig ISM + the spoke handlers
  (`/v4-security-foundations`, `/adversarial-uniswap-hooks` for hook-adjacent surface,
  `/claude-tenderly-auditor` + Codex adversarial on a Tenderly testnet fork).
- Publish our chains to the **Hyperlane registry** (Arc when mainnet opens) so tooling/agents
  resolve addresses.
- Monitoring: validator liveness, relayer balance, gas oracle freshness, undelivered messages,
  warp-route rate-limit alerts.

## Phase 5 — Mainnet rollout
Re-run Phases 1–4 on **Avalanche C-Chain mainnet** first (where we already operate), then each
EVM mainnet we add. **Arc mainnet** joins the day Circle opens it (no public RPC / unsupported
today — hard external blocker, not ours to unblock).

---

## Hard constraints / risks
- **Arc mainnet is not live for us** — no public RPC, Circle unsupported. "Prod on Arc" is
  blocked externally until that ships. Testnet-hardening (this plan's Phase 1–4) is the
  template; mainnet means Avalanche + friends until Arc opens.
- **Validator key management** is the #1 security surface — KMS only, never env/committed.
- **Gas:** Arc native gas is 18-dec USDC; budget IGP + relayer funding automation per chain.
- **Replace trusted-relayer ISM before ANY value** (Hyperlane's own manifest note).
- **Audit gate** before mainnet value flows through warp routes / multisig ISM.

## Existing assets to build on (don't re-author)
- `hyperlane/arc-testnet/core-config.yaml`, `agent-config.json`
- `hyperlane/warp-routes/{MXNB,JPYC,AUDF,QCAD,cirBTC}.yaml` (authored, undeployed)
- `package.json` → `hyperlane:arc:deploy-core`, `:fuji:deploy-arc-ism`, `:arc:agent-config`,
  `:arc:test-dispatch`, `:fuji:test-message`, `:bridge:mxnb[:full]`
- `scripts/hyperlane-bridge-mxnb.ts` (dispatch-only bridge demo → extend to `--full` post-warp)
- `contracts/src/spoke/{FxSpoke,FxSpokeIntentRouter}.sol`, `ghost/FxGhostSpokeRouter.sol`,
  `hub/FxHubMessageReceiver.sol`

## Immediate next step
Phase 2 headline win is closest (configs exist): deploy the JPYC + MXNB warp routes on
Fuji↔Arc-testnet and prove a round-trip — but land the **Phase-1 multisig ISM first** so the
warp routes deploy behind real security, not the trusted relayer.
