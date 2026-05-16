# Gateway end-to-end flow

How to move USDC liquidity Fuji ↔ Arc via Circle Gateway.

## Two flows: bypass vs hook-routed

| | **Bypass (live today)** | **Hook-routed (needs Stage 6)** |
|---|---|---|
| Source | `deployer EOA` calls `GatewayWallet.depositFor` directly | `HUB` calls `FxGatewayHook.lockForRemote` |
| Destination caller | `0x0` (anyone) | `FxGatewayHook` (locked) |
| Destination recipient | deployer EOA on dest | `FxGatewayHook` → forwards to HUB |
| Mint trigger | `deployer EOA` calls `GatewayMinter.gatewayMint` directly | `HUB` calls `FxGatewayHook.mintFromRemote` |
| Use case | Smoke test the signer + Circle integration | Production protocol-atomic FX trades |
| Blocker | None — works today | Hub needs `relayToRemoteHub`/`relayMintFromRemote` shims (small contract change) |

The signer service (`packages/sdk/scripts/gateway-signer.ts`) supports both modes via the `--bypass` flag on `sign-and-attest`.

## Bypass e2e procedure (live testnet, ~$0.10 USDC)

Prereqs: deployer wallet `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` funded with at least **2 USDC on Avalanche Fuji** via [faucet.circle.com](https://faucet.circle.com). Native AVAX for gas is essentially free on Fuji.

### 1. Deposit USDC into Gateway on Fuji

```bash
source .env.local
bun packages/sdk/scripts/gateway-signer.ts deposit fuji 2000000
# 2_000_000 atomic = $2.00 USDC (Gateway needs deposit ≥ amount + ~$0.02 fee)
```

This calls `GatewayWallet.depositFor(USDC, deployer, $2)`. Wait ~10 seconds for Circle's operator to pick up the deposit (Fuji has near-instant finality).

### 2. Confirm balance

```bash
bun packages/sdk/scripts/gateway-signer.ts balances
# domain=1   2 USDC
# domain=26  0 USDC
```

### 3. Sign a burn intent + fetch attestation (bypass mode)

```bash
bun packages/sdk/scripts/gateway-signer.ts sign-and-attest gateway-fuji-to-arc-usdc 100000 --bypass
# 100_000 atomic = $0.10 — pick something small for the first run
```

The script:
1. Builds the `BurnIntent` with `destinationRecipient = deployer-on-arc`, `destinationCaller = 0` (so anyone can mint)
2. Signs it as EIP-712 typed data with the deployer EOA
3. POSTs the signed intent to `https://gateway-api-testnet.circle.com/v1/transfer`
4. Receives back `{ attestation: bytes, signature: bytes }`
5. Prints both hex strings — copy them for step 4

Expected latency: ~500ms-2s (Circle's attestor service).

### 4. Mint on Arc

```bash
bun packages/sdk/scripts/gateway-signer.ts gateway-mint arc <attestation-hex> <signature-hex>
```

This calls `GatewayMinter.gatewayMint(...)` on Arc. USDC mints to the deployer on Arc.

### 5. Verify

```bash
cast call 0x3600000000000000000000000000000000000000 \
  'balanceOf(address)(uint256)' \
  0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69 \
  --rpc-url https://rpc.testnet.arc.network
# expect ~99980 (=$0.0998, minus ~$0.0002 fee)
```

If you see USDC, **the full Gateway flow works end-to-end** on live testnets. Circle's attestation chain is verified. Our signer is correct. Their operator is happy with our EIP-712.

## Hook-routed flow (when Stage 6 lands)

Same shape, but every call goes through `FxGatewayHook` and `FxHubMessageReceiver`:

```
HUB.relayToRemoteHub(amount)
  → FxGatewayHook.lockForRemote(amount)
    → GatewayWallet.depositFor(USDC, authority=EOA, amount)

[off-chain]
  signer-service watches LockedForRemote event
  → builds intent with destinationCaller=remote-hook, destinationRecipient=remote-hook
  → signs + POSTs
  → attestation back

HUB.relayMintFromRemote(attestation, signature)
  → FxGatewayHook.mintFromRemote(attestation, signature)
    → GatewayMinter.gatewayMint(...)
      → USDC mints to FxGatewayHook
    → hook forwards to HUB
```

Stage 6 plumbing needed:

```solidity
// FxHubMessageReceiver additions:

address public gatewayBridge;          // = FxGatewayHook on this chain
mapping(address => bool) public bufxCallers;

function setGatewayBridge(address bridge) external onlyOwner {
    gatewayBridge = bridge;
}
function setBufxCaller(address bufx, bool allowed) external onlyOwner {
    bufxCallers[bufx] = allowed;
}

function relayToRemoteHub(uint256 amount) external {
    if (!bufxCallers[msg.sender] && msg.sender != owner()) revert NotAuthorized();
    USDC.safeTransferFrom(msg.sender, gatewayBridge, amount);
    IFxGatewayHook(gatewayBridge).lockForRemote(amount);
}

function relayMintFromRemote(bytes calldata attestation, bytes calldata signature) external {
    if (!bufxCallers[msg.sender] && msg.sender != owner()) revert NotAuthorized();
    IFxGatewayHook(gatewayBridge).mintFromRemote(attestation, signature);
}
```

~50 LOC + 1 test. Easy lift. Triggers a hub redeploy on both Fuji + Arc and a spoke re-migration (since `FxHubMessageReceiver` address changes again).

## Watch mode (daemon)

For continuous operation:

```bash
bun packages/sdk/scripts/gateway-signer.ts watch
# Streams LockedForRemote events from both hooks
# For each: builds intent, signs, POSTs, appends attestation to reports/gateway-attestations.jsonl
# Operator (or automation) reads the file and submits mintFromRemote on dest
```

Output schema (`reports/gateway-attestations.jsonl`):
```json
{
  "ts": "2026-05-16T01:23:45.678Z",
  "sourceChainId": 43113,
  "routeId": "gateway-fuji-to-arc-usdc",
  "amount": "100000",
  "authority": "0x0646...c69",
  "lockTxHash": "0x...",
  "attestation": "0x...",
  "attestationSignature": "0x...",
  "latencyMs": 847
}
```

## Authority rotation timeline

Until ~mid-July 2026 (Corey's EIP-1271 ETA on Gateway): authority = deployer EOA `0x0646...c69`. Signer service is the only thing with the key.

After 1271 lands: authority = `FxHubMessageReceiver` contract via `setAuthority(...)`. Burn intents become contract-signed via `isValidSignature`. Signer service retires (or becomes a thin relayer for the hub's intent payloads).
