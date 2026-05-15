# Tenderly Claude Handoff Prompt

Use this prompt when handing Telaraña to Claude for Tenderly vnet testing.

```text
You are testing the Telaraña smart-contract protocol on Tenderly.

Repository:
/Users/criptopoeta/coding-dojo/fx-onchain

Branch:
codex/frontend-handoff-avalanche-fx

Primary goal:
Run a Tenderly-focused verification pass for the Telaraña handoff. Confirm that
the local smart-contract suite is green, then test the deployed or deployable
Tenderly environment without changing protocol scope.

Product framing:
Telaraña is a cross-chain onchain forex credit hub. Users can enter from
supported chains with USDC or EURC where Circle supports the route, move USDC
between hubs through Circle Gateway, route into hub FX markets, and borrow,
lend, or prepare future spot FX requests against supported stablecoin pairs.

Do not build:
- BuFX
- perps
- a full RFQ engine
- production ZK circuits
- production Ghost liquidity
- new core financial logic outside the current adapter/wrapper model

Read first:
- README.md
- AGENTS.md
- docs/SPEC.md
- docs/FRONTEND_INTEGRATION_PROMPT.md
- docs/future/CIRCLE_GATEWAY_HUB_LIQUIDITY.md
- docs/GHOST_MODE_PRIVACY_HOOKS.md
- docs/BUCKET_ANALYSIS_SMART_CONTRACTS_2026-05-15.md
- deployments/tenderly-base-sepolia.json

Required local verification:
1. git status --short --branch
2. bun run contracts:guardrails
3. bun run contracts:test
4. bun run contracts:test:fork
5. bun run sdk:test
6. bun run sdk:build

Tenderly testing focus:
1. Confirm the Tenderly Base Sepolia deployment manifest is readable:
   deployments/tenderly-base-sepolia.json
2. If testing the Avalanche basket drill, use:
   contracts/script/DeployTenderlyAvalancheBasket.s.sol
   and write/read:
   deployments/tenderly-avalanche-fuji-basket.json
3. Use Tenderly admin RPC only from .env.local or README. Do not commit secrets.
4. Use Tenderly RPC helpers only for test setup:
   - tenderly_setBalance
   - tenderly_setErc20Balance
   - evm_increaseTime
   - evm_mine
5. Smoke the protocol flows that are in scope:
   - public FxSpoke USDC/EURC entry shape
   - FxHubMessageReceiver stranded-deposit recovery behavior
   - FxMarketRegistry supply/borrow/repay/withdraw shape
   - FxSwapHook quote/deposit/redeem/swap invariant behavior
   - TelaranaGatewayHubHook trusted-executor Gateway mint path
   - Ghost Mode spoke entry, commitment registry, withdrawal scaffold, and KYC hook gate

Important constraints:
- Gateway is USDC-only in the current Telarana config.
- CCTP is USDC/EURC-only and only where Circle supports the route.
- Ghost Mode uses Bufi Wallet / RO-KYC pass semantics, not Circle Wallet.
- Public pools remain permissionless. Ghost routes are separate.
- IFxOracle is the only price-read surface.
- FxSpoke.enterHub must use explicit beneficiary. Never derive beneficiary from msg.sender.
- Do not use tx.origin.

Expected output:
Return a concise Tenderly test report with:
- branch and commit SHA
- commands run and pass/fail counts
- Tenderly RPC/network used
- deployment manifest used
- transaction hashes for any Tenderly broadcasts
- any blocked step and the exact missing env var, balance, contract address, or RPC behavior
- recommended next action

If a contract or test fails, stop and provide the smallest reproducible command.
Do not patch production contracts unless the failure is clearly in this branch
and the fix is covered by a new regression test.
```
