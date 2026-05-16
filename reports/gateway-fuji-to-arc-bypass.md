# Gateway Fuji → Arc proof-of-life

Both flows verified end-to-end on live testnet on **2026-05-15** using deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`.

## TL;DR

| Flow | Path | Latency (Circle attestor) | Status |
|---|---|---|---|
| **Bypass** (no hook) | `deployer EOA → Gateway → Gateway → deployer EOA` | **397ms** | ✅ |
| **Hook-routed** (Stage 6) | `deployer → hub.relayToRemoteHub → hook.lockForRemote → Gateway → Gateway → hook.mintFromRemote → hub (relayed)` | **349ms** | ✅ |

Sub-500ms attestation, ~30s total wallclock per cross-hub move (mostly Fuji finality + Circle operator pickup window). Confirms the architect's HFT-primitive thesis.

---

## Flow 1 — Bypass (sanity check, no hook involved)

Used to validate that our EIP-712 typed-data layout, signature recovery, and POST format work against Circle's testnet API before exercising any of our contracts.

### Setup
- Fuji deployer balance ahead of run: **10 USDC**
- BurnIntent `destinationCaller = 0x0` (anyone can mint), `destinationRecipient = deployer on Arc`

### Steps

| # | Step | Tx hash | Chain | Latency |
|---|---|---|---|---|
| 1 | Approve `GatewayWallet` for 2 USDC | `0x7de6daa2d0a2ea06b6b2761ce82d2955a7fb7634407a54f7e3a46c09922492ca` | Fuji | — |
| 2 | `GatewayWallet.depositFor($2, depositor=EOA)` | `0x84966b1e598b8c9297dbe5d26d62a0f9e94f44e72ae19072aec26d8b0bb95937` | Fuji | — |
| 3 | Wait for Circle operator to observe finalized deposit | — | — | ~12s |
| 4 | `/balances` → Fuji domain 1 reports `2.000000 USDC` ✓ | — | — | — |
| 5 | Build BurnIntent for `gateway-fuji-to-arc-usdc`, $0.10, `--bypass` | — | local | <1ms |
| 6 | EIP-712 sign with deployer EOA | — | local | <1ms |
| 7 | `POST https://gateway-api-testnet.circle.com/v1/transfer` → `{attestation, signature}` | — | Circle | **397ms** |
| 8 | `GatewayMinter.gatewayMint(attestation, sig)` | `0x60418160f909cbeea5fd083c436f3d48a7d75d95800759847356fc308c45ac1b` | Arc | gas=140641 |
| 9 | `/balances` → Fuji domain 1 reports `1.879995 USDC` ✓ | — | — | — |

### Fee math
- Transferred: $0.100000
- Fee retained by Circle: $0.020005 (~20bps)
- Net debit from Fuji Gateway balance: $0.120005

---

## Flow 2 — Hook-routed (full Stage 6 protocol path)

The path BUFX and FxSwapHook will exercise for cross-hub FX trades. Every USDC move goes through our contracts; Gateway is invisible to the caller.

### Setup
- Stage 6 contracts redeployed earlier the same day:
  - Fuji `FxHubMessageReceiver` `0x7eAdfD0c08dd6544f763285bBD31be14179d594B`
  - Fuji `FxGatewayHook` `0x7dA191bfB85D9F14069228cf618519BFb41f371E`
  - Arc `FxHubMessageReceiver` `0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C`
  - Arc `FxGatewayHook` `0x2931C50745334d6DFf9eC4E3106fE05b49717DF1`
- `hub.setGatewayHook(hook)` wired on each chain
- Deployer EOA is owner of both hubs (`relayCallers` whitelist empty pending BUFX)
- BurnIntent `destinationCaller = Arc hook` (locks mint to our contract only), `destinationRecipient = Arc hook`

### Steps

| # | Step | Tx hash | Chain | Latency |
|---|---|---|---|---|
| 1 | Approve Fuji hub for 100000 USDC | `0x9e9637089a9f4996ee1d062b37db93120f38d033d1a5dbd9d7212734073c5e63` | Fuji | — |
| 2 | `hub.relayToRemoteHub(100000)` — pulls USDC, approves hook, calls hook.lockForRemote, drops approval | `0x35b646a26bd6e93842f8ec9cf356b977c92196d8cb904b6226cfd04abfe8e040` | Fuji | — |
| 3 | Wait for Circle operator to observe deposit | — | — | ~12s |
| 4 | `/balances` → Fuji domain 1 reports balance increased by 0.10 USDC ✓ | — | — | — |
| 5 | Build BurnIntent for `gateway-fuji-to-arc-usdc`, $0.10, **no `--bypass`** (full hook-locked) | — | local | <1ms |
| 6 | EIP-712 sign with deployer EOA | — | local | <1ms |
| 7 | `POST /transfer` → `{attestation, signature}` | — | Circle | **349ms** |
| 8 | `hub.relayMintFromRemote(attestation, sig)` on Arc — calls hook.mintFromRemote, hook gets USDC, forwards to hub | `0xe430d026e691147f4e96a87aff558332e0a94ff9abe8144fe8059c75439e9aaa` | Arc | gas=187410 |
| 9 | `cast call USDC.balanceOf(ArcHub)` → `100000` ($0.10) ✓ | — | — | — |

### Event chain (from tx `0x35b646a2…`, Fuji `relayToRemoteHub`)
```
USDC.Transfer(deployer → hub, 100000)             ← caller funds hub
USDC.Approval(hub → hook, 100000)                 ← hub approves hook
USDC.Transfer(hub → hook, 100000)                 ← hook pulls
USDC.Approval(hook → GatewayWallet, 100000)       ← hook approves Gateway
USDC.Transfer(hook → GatewayWallet, 100000)       ← deposit
GatewayWallet.Deposited(USDC, depositor=EOA, sender=hook, 100000)
USDC.Approval(hook → GatewayWallet, 0)            ← hook scrubs allowance
FxGatewayHook.LockedForRemote(100000, authority=EOA)
USDC.Approval(hub → hook, 0)                      ← hub scrubs allowance
FxHubMessageReceiver.RelayedToRemoteHub(deployer, 100000, hook)
```

### Event chain (from tx `0xe430d026…`, Arc `relayMintFromRemote`)
```
GatewayMinter mint authority bump
USDC.Approval (Gateway internal)
USDC.Transfer(0 → hook, 100000)                   ← mint
GatewayMinter.AttestationUsed(...)
USDC.Transfer(hook → hub, 100000)                 ← forward to hub
FxGatewayHook.MintedFromRemote(100000, forwardedTo=hub)
FxHubMessageReceiver.RelayedMintFromRemote(deployer, 100000, hook)
```

---

## What this proves

1. **The EIP-712 BurnIntent typed-data layout in `packages/sdk/src/gateway.ts` is wire-compatible with Circle's attestor service** — our signature recovers to the expected depositor on both bypass and hook-routed runs.
2. **Stage 6 plumbing (`relayToRemoteHub` + `relayMintFromRemote`) works exactly as designed** — owner-gated, pulls USDC from caller, scrubs allowances at every step, hook forwards minted USDC to hub.
3. **`destinationCaller` lock works as the security primitive** — only the Arc hook could submit the mint, so even a leaked attestation can't be claimed by anyone else.
4. **End-to-end latency is HFT-grade** — 349ms Circle attestor, ~30s wallclock dominated by Fuji finality + operator observation window. Sub-block on Arc once the attestation is in hand.
5. **The off-chain signer service runs from a Bun CLI with the deployer EOA** — `packages/sdk/scripts/gateway-signer.ts info|balances|sign-and-attest|gateway-mint|watch`.

## What's next

1. **Whitelist BUFX as a relay caller** — `hub.setRelayCaller(bufxAddress, true)` on both Fuji + Arc once their contracts deploy.
2. **FxSwapHook before/after wiring** — invoke `relayToRemoteHub` / `relayMintFromRemote` from inside Uniswap V4 hook callbacks so cross-hub FX trades become protocol-atomic.
3. **Mid-July 2026 — EIP-1271 authority rotation** — `setAuthority(hub)` on each hook, hub implements `isValidSignature` that gates which BurnIntents the protocol authorizes (domain pair, value cap, deadline). Off-chain signer service retires.
4. **Larger-scale dogfooding** — first run was $0.10. Architecture targets multi-million per intent. Stress test on Tenderly Pro snapshot branches before mainnet.
5. **Permissionless gateway-signer mode** — once 1271 lands, anyone can run the signer to relay attestations; trust is in the contract signature, not the EOA holding the key.
