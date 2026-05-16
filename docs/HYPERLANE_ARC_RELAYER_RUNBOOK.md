# Hyperlane Arc relayer runbook

Status: Arc Testnet does not appear in the canonical Hyperlane Mailbox table as
of 2026-05-15, so Forex Telarana ships a local Hyperlane registry entry under
`hyperlane/registry/chains/arctestnet/`.

This lane is for Hyperlane intents and non-Circle asset routes. CCTP remains
Circle-only for USDC and EURC where Circle supports both endpoints.

## Deployment scope

| Item | Value |
|---|---|
| Hyperlane chain name | `arctestnet` |
| Arc Testnet chain id / domain id | `5042002` |
| Primary RPC | `https://rpc.testnet.arc.network` |
| Explorer | `https://testnet.arcscan.app` |
| Native gas token | USDC-like native gas, 18 decimal fee units |
| Arc ERC-20 USDC | `0x3600000000000000000000000000000000000000` |
| Arc ERC-20 EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| Initial owner / relayer | `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` |
| Initial ISM | `trustedRelayerIsm` for testnet bootstrap only |

## Deployed 2026-05-15

Arc Testnet core is deployed and recorded in
`hyperlane/registry/chains/arctestnet/addresses.yaml`. A compact deployment
manifest for handoff lives at `deployments/hyperlane-arc-testnet.json`.

| Contract | Address |
|---|---|
| Mailbox | `0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9` |
| ProxyAdmin | `0x32b7aF2464c654B77B8E0Fe2516FB8b1029CA419` |
| Default `trustedRelayerIsm` | `0x263DA0b912EFD06Ea3E8C954Dd2B60A3fdC79241` |
| MerkleTreeHook | `0xccceb5B90d9C1d9c5f8CcF755E4f37A849C8Ca11` |
| ProtocolFee | `0x971b6ED14521f354eD13d64506Bf47D84E70F4fc` |
| InterchainAccountRouter | `0x113A539625D208b5EcC59f300Be14b9b3508E559` |
| ValidatorAnnounce | `0xbBc9AE9dbd3F6D3dB672F0CA2419d0f4C8513062` |
| QuotedCalls | `0x1527f0230e07B202812A0F0E437995323A1a98cB` |
| TestRecipient | `0x144bf6521C4B843091BC35E98d80F6Ce402d20f9` |

Fuji app-specific ISM for Arc-origin hub receiver messages:

| Contract | Address |
|---|---|
| TrustedRelayerIsm | `0x3f5d9B44aa1D59D26B20862D91533d60B32d9aFa` |

Smoke results:

| Direction | Result | Reference |
|---|---|---|
| Fuji -> Arc Testnet | PASS, self-relayed | message `0xb5987ac64421df6c127f9d425559a5b7ddee68258110666553ef55e27ff752ca`, relay tx `0x33ea34bb784c8332a8e4564da07bbe7114978703b937d47e84670af6b52e09be` |
| Arc Testnet -> Fuji | PASS dispatch only | message `0x80b50f405aa6b4ee2a95d6a67c19f7442fed650b7b3f0043c8cbf8079becdc9d`, dispatch tx `0x156dbb93d61d726a3c7676678245163042f6e2525fc3b965f9d1936a30daf619` |

Full Arc -> Fuji processing must target a Fuji recipient that implements
`interchainSecurityModule()` and returns the app-specific ISM above. A generic
Fuji recipient still fails with `No ISM found for origin: 5042002` because
Fuji's canonical default ISM does not route Arc yet.

The initial config intentionally mirrors the old Wormhole hub/spoke pattern:
one allowlisted message transport, one hub-side acceptance layer, and explicit
spoke registration before any user asset can affect lending state.

## Deploy core contracts

Use a funded Arc Testnet deployer. Keep the private key in the environment or a
keystore; do not commit it and do not pass it as a CLI argument.

```bash
export HYP_KEY="<arc-funded-private-key>"
bun run hyperlane:arc:deploy-core
```

After deployment, the Hyperlane CLI writes public contract addresses to:

```text
hyperlane/registry/chains/arctestnet/addresses.yaml
```

Commit that file. It is the handoff artifact Circle needs for the Arc-side
Mailbox, hooks, ISM factories, ICA router, and ValidatorAnnounce addresses.

## Generate relayer config

Generate an agent config for Arc Testnet <-> Fuji:

```bash
bun run hyperlane:arc:agent-config
```

This writes:

```text
hyperlane/arc-testnet/agent-config.json
```

The file contains public chain metadata and contract addresses. It does not
contain signing keys.

The Arc bootstrap core does not deploy an Interchain Gas Paymaster, so the agent
config pins `arctestnet.interchainGasPaymaster` to `0x0`. That is acceptable for
a directly funded test relayer, but Circle should decide whether to add a
paymaster hook before external users rely on the lane.

## Deploy Fuji App ISM

Fuji's canonical Hyperlane default ISM does not know Arc Testnet domain
`5042002`. Arc -> Fuji messages dispatch successfully, but a generic Fuji
recipient cannot process them until the recipient specifies an app-specific ISM.

For the fx-Telarana hub receiver bootstrap, deploy a Fuji `trustedRelayerIsm`:

```bash
export HYP_KEY="<fuji-funded-private-key>"
bun run hyperlane:fuji:deploy-arc-ism
```

Then configure the hub receiver after deployment:

```bash
cast send "$FX_HYPERLANE_HUB_RECEIVER" \
  "setInterchainSecurityModule(address)" \
  "$(jq -r '.address' hyperlane/fuji/arc-testnet-trusted-relayer-ism-address.json)" \
  --rpc-url "$FUJI_RPC_URL" \
  --account "$FOUNDRY_KEYSTORE_ACCOUNT"
```

Do not set a null ISM on the hub receiver. A null ISM would allow forged
origin/sender/body messages to reach the app before the receiver's registry
checks run.

## Run a test relayer

The testnet bootstrap config uses `trustedRelayerIsm`, so a validator is not
required for smoke tests. The relayer signer must be funded with native USDC on
Arc and AVAX on Fuji because it submits destination `Mailbox.process()` calls.

```bash
docker pull --platform linux/amd64 ghcr.io/hyperlane-xyz/hyperlane-agent:agents-v2.2.0
mkdir -p hyperlane/arc-testnet/hyperlane_db_relayer

docker run \
  -it \
  -e CONFIG_FILES=/config/agent-config.json \
  --mount type=bind,source="$(pwd)"/hyperlane/arc-testnet/agent-config.json,target=/config/agent-config.json,readonly \
  --mount type=bind,source="$(pwd)"/hyperlane/arc-testnet/hyperlane_db_relayer,target=/hyperlane_db \
  ghcr.io/hyperlane-xyz/hyperlane-agent:agents-v2.2.0 \
  ./relayer \
  --db /hyperlane_db \
  --relayChains arctestnet,fuji \
  --defaultSigner.key "$HYP_KEY"
```

For a local reverse-direction delivery smoke without a long-running agent:

```bash
export HYP_KEY="<arc-and-fuji-funded-private-key>"
bun run hyperlane:fuji:test-message
```

For Arc -> Fuji before the hub receiver is deployed, only test dispatch:

```bash
export HYP_KEY="<arc-funded-private-key>"
bun run hyperlane:arc:test-dispatch
```

Generic Fuji recipients use Fuji's default ISM, which currently rejects Arc
origin domain `5042002`. Full Arc -> Fuji processing must target a recipient
that returns the app-specific ISM above.

## Production handoff to Circle

Before real value, Circle should replace this bootstrap posture:

- Transfer `owner` / `proxyAdmin.owner` / `protocolFee.owner` to Circle's
  nominated Arc operations wallet or Safe-equivalent.
- Replace `trustedRelayerIsm` with a multisig ISM. Hyperlane's production docs
  recommend multisig ISMs over trusted relayer ISMs.
- Replace the Fuji app-specific `trustedRelayerIsm` on `FxHyperlaneHubReceiver`
  with a multisig ISM before routing value-bearing Arc intents.
- Operate at least one Arc-funded relayer. A single relayer can cover many
  chains, but production should use managed keys such as AWS KMS.
- Operate validators or contract with validator operators if using a multisig
  ISM. Do not use local filesystem checkpoints for production.
- Register the Arc Mailbox and relayer health checks in Circle monitoring.
- Only after the protocol deploys `FxSpokeIntentRouter` on Arc, register it in
  `FxHyperlaneHubReceiver.setTrustedSpoke(5042002, router)`.

## Protocol integration checks

Once Arc Hyperlane core exists and the protocol contracts are deployed:

1. Add `hyperlane` addresses to the SDK manifest for `ChainId.ArcTestnet`.
2. Deploy `FxSpokeIntentRouter` on Arc using the Arc Mailbox address.
3. On the Avalanche/Fuji hub, call:
   - `FxHyperlaneHubReceiver.setTrustedSpoke(5042002, arcRouter)`
   - `FxHyperlaneHubReceiver.setRouteAsset(routeId, token, allowed)`
4. Send an intent message from Arc and verify the receiver emits the expected
   intent event without executing an unregistered or unfunded asset.
