# Hyperlane asset spokes

**Status:** Intent-lane contracts and SDK scaffolding are implemented:
`FxSpokeIntentRouter` dispatches typed Hyperlane messages and
`FxHyperlaneHubReceiver` accepts only registered spokes/routes/assets before a
hub action can execute. No Warp Route is live until a `routeId` and per-chain
route token addresses are added to the deployment manifest.

**Purpose:** Circle Gateway is USDC-only in the current design, and CCTP V2 is
used only for Circle-supported USDC/EURC routes. Hyperlane Warp Routes and
approved issuer-specific routes are the path for other FX assets that a user
holds on another chain and wants to bring to the Avalanche hub as collateral,
lend supply, or swap input.

Hyperlane docs used for this integration:

- Docs index: <https://docs.hyperlane.xyz/llms.txt>
- Deploy Hyperlane to a new EVM chain: <https://docs.hyperlane.xyz/docs/guides/chains/deploy-hyperlane>
- Run a Hyperlane relayer: <https://docs.hyperlane.xyz/docs/operate/relayer/run-relayer>
- Bridge a token / Warp Route deploy flow: <https://docs.hyperlane.xyz/docs/guides/quickstart/deploy-warp-route>
- Warp Route interface: <https://docs.hyperlane.xyz/docs/applications/warp-routes/interface>
- Warp Route token types: <https://docs.hyperlane.xyz/docs/applications/warp-routes/types>
- Interchain Accounts: <https://docs.hyperlane.xyz/docs/applications/interchain-account/overview>
- Send/receive messages: <https://docs.hyperlane.xyz/docs/reference/messaging/send> and <https://docs.hyperlane.xyz/docs/reference/messaging/receive>
- Modular security / ISMs: <https://docs.hyperlane.xyz/docs/protocol/ISM/modular-security>

## 1. Split the bridge lanes

| Asset lane | Bridge primitive | Scope | Receiver model |
|---|---|---|---|
| USDC | Circle CCTP V2 | Canonical USDC burn/mint between supported chains | Existing `FxSpoke.enterHub(...)` and `FxHubMessageReceiver` |
| EURC | Circle CCTP V2 where Circle supports EURC on both ends | Canonical EURC burn/mint only on Circle-supported routes | Same CCTP lane; never mock EURC where Circle testnet EURC exists |
| Cross-chain intent | Hyperlane Mailbox | Spoke command lane for route + market + action metadata | `FxSpokeIntentRouter.sendIntent(...)` to `FxHyperlaneHubReceiver.handle(...)` |
| AUDF, JPYC, MXNB, KRW1 | Hyperlane Warp Routes or approved issuer-specific routes | Bring approved ERC-20 FX assets to the Avalanche hub | Route transfer to user, ICA, or hub receiver after route deployment |
| ZCHF | Issuer/CCIP asset on Avalanche | Treat Avalanche ZCHF as the supported hub asset | Do not replace with a Hyperlane synthetic without risk approval |

Do not turn the CCTP `FxSpoke` into an arbitrary ERC-20 bridge. CCTP remains
strictly scoped to Circle-supported USDC and EURC routes. Hyperlane is a second
spoke component: `FxSpokeIntentRouter` carries typed user intent and route
metadata, while Warp Routes or approved issuer-specific routes handle other
asset movement under separate manifests, monitoring, and risk treatment.

## 2. Token identity rule

A Hyperlane-delivered token is not automatically the issuer-canonical token on
Avalanche.

There are two acceptable hub-token models:

1. **Collateral-released canonical token:** the Avalanche side of the Warp Route
   is collateral-backed and funded with issuer tokens. Incoming transfers release
   `AUDF`, `JPYC`, `MXNB`, or `KRW1` at the issuer address already supported by
   the hub.
2. **Hyperlane synthetic token:** the route mints an `hTOKEN` representation on
   Avalanche. This must be listed as a separate token address with separate caps,
   market ids, receipt tokens, and monitoring. Do not label it as issuer-native.

The SDK exposes this distinction with `hubTokenSource`:

- `issuer`: the token is already issuer/bridge canonical on the hub.
- `collateralReleased`: a funded hub collateral route releases the issuer token.
- `hyperlaneSynthetic`: the route mints a synthetic route token.
- `mock`: testnet-only mock.
- `pending`: address not deployable yet.

## 3. Mainnet Hyperlane core addresses

Avalanche C-Chain is the production hub.

| Chain | Hyperlane domain | Mailbox | Interchain Gas Paymaster | ICA router |
|---|---:|---|---|---|
| Avalanche | `43114` | `0xFf06aFcaABaDDd1fb08371f9ccA15D73D51FeBD6` | `0x95519ba800BBd0d34eeAE026fEc620AD978176C0` | `0x2c58687fFfCD5b7043a5bF256B196216a98a6587` |

Fuji testnet core:

| Chain | Hyperlane domain | Mailbox | Interchain Gas Paymaster | ICA router |
|---|---:|---|---|---|
| Fuji | `43113` | `0x5b6CFf85442B851A8e6eaBd2A4E4507B5135B3B0` | `0x6895d3916B94b386fAA6ec9276756e16dAe7480E` | not published in Hyperlane address table |

Arc Testnet local core, deployed 2026-05-15:

| Chain | Hyperlane domain | Mailbox | Interchain Gas Paymaster | ICA router |
|---|---:|---|---|---|
| Arc Testnet | `5042002` | `0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9` | `0x0000000000000000000000000000000000000000` | `0x113A539625D208b5EcC59f300Be14b9b3508E559` |

Fuji app-specific ISM for Arc-origin hub receiver messages:
`0x3f5d9B44aa1D59D26B20862D91533d60B32d9aFa`.

If Fuji needs transfer-and-call before an official testnet ICA router exists,
deploy our own ICA router or use a two-step UX: Warp Route transfer to the user
on Fuji, then the user calls `FxMarketRegistry` directly.

## 4. First deployable route set

Use the Hyperlane CLI flow (`hyperlane warp init`, then `hyperlane warp deploy`)
and store artifacts from `$HOME/.hyperlane/deployments/warp_routes/<routeId>/`
in the matching deployment manifest.

| Asset | Mainnet hub token | Desired hub model | Initial origins | Status |
|---|---|---|---|---|
| AUDF | `0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b` | `collateralReleased` | Ethereum, Base, Polygon | planned |
| JPYC | `0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB` | `collateralReleased` | Ethereum, Polygon | planned |
| MXNB | `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA` | `collateralReleased` | Ethereum, Arbitrum One | planned |
| KRW1 | `0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318` | `collateralReleased` only if additional origins exist | none yet | pending |
| ZCHF | `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` | issuer/CCIP hub asset | none | disabled for Hyperlane |

For Fuji drills, deploy mocks for AUDF, JPYC, MXNB, KRW1, and ZCHF on the
selected origin testnets and a matching route to Fuji. Keep Circle Fuji EURC at
`0x5E44db7996c682E92a960b65AC713a54AD815c6B`; do not deploy `MockEURC`.

## 5. Transfer-and-call pattern

The production UX should support two Hyperlane modes.

### 5.1 Two-step, lowest risk

1. User approves the origin Warp Route for the source asset plus route fee.
2. User calls `transferRemote(destinationDomain, recipientBytes32, amount)`.
3. Asset arrives on Avalanche.
4. User switches to Avalanche and calls `FxMarketRegistry.supply`,
   `supplyCollateral`, or the swap route directly.

This is the first testnet implementation because it does not add new custody or
remote execution contracts.

### 5.1.1 Typed intent lane

The implemented low-level flow is:

1. User calls `FxSpokeIntentRouter.quoteIntent(...)` on the source/spoke chain.
2. User calls `FxSpokeIntentRouter.sendIntent{value: fee}(...)`.
3. Hyperlane Mailbox delivers the typed intent to `FxHyperlaneHubReceiver`.
4. Hub receiver validates:
   - origin domain + spoke sender are registered,
   - route + input token are allowlisted,
   - market is live in `FxMarketRegistry`,
   - nonce has not been consumed.
5. Either:
   - the beneficiary executes `FxHyperlaneHubReceiver.executeIntent(intentId)`
     after approving the receiver for pull-based actions, or
   - the allowlisted Warp route delivers funds to the receiver and calls
     `executeRoutedIntent(intentId)`.

Supported execution actions are `Supply`, `SupplyCollateral`, `Repay`, and
`Borrow`. Token-funded actions require a registered route and exact input token.
`Borrow` uses `inputToken = address(0)` and `route = address(0)`, and requires
the beneficiary to approve the hub receiver as a borrow delegate with
`FxMarketRegistry.setBorrowDelegate(...)` while still authorizing the registry
inside Morpho.

### 5.2 Transfer-and-call with ICA

1. UI computes the user's remote ICA address.
2. Warp Route sends tokens to that remote ICA.
3. ICA `callRemote` executes the hub-side action after the assets arrive.

This is the one-click target, but it must preserve user recovery. If the hub call
fails, tokens stay in the user's ICA, not in a shared protocol account.

Registry implication: `FxMarketRegistry.borrow`, `withdraw`, and
`withdrawCollateral` remain self-gated. Only `borrowDelegated(...)` is exposed
for account-approved delegates; withdraw paths are intentionally not delegated.
If an ICA executes self-gated calls, the position owner is the ICA.

## 6. Market onboarding checklist

Every Hyperlane route token that becomes a hub market asset must pass the normal
stablecoin checklist plus route-specific checks:

- [ ] Route `routeId` committed to deployment manifest.
- [ ] Hub token address classified as `issuer`, `collateralReleased`, or
  `hyperlaneSynthetic`.
- [ ] Mailbox, Interchain Gas Paymaster if used, and app-specific ISM
  addresses pinned.
- [ ] Custom or aggregate ISM reviewed for the route. Do not rely on an unknown
  default for production TVL.
- [ ] Route transfer limits configured where available.
- [ ] `FxOracle` configured through `IFxOracle` only.
- [ ] Morpho markets created for each direction needed.
- [ ] `FxMarketRegistry` entries added and `isPoolLive` tested.
- [ ] Receipt tokens deployed when the market needs SDK/UI receipt accounting.
- [ ] Tenderly/Fuji drill covers transfer, hub supply collateral, borrow, repay,
  withdraw, and failed hub-call recovery.

## 7. Front-end requirements

The app should present CCTP and Hyperlane as different lanes:

- CCTP lane: source asset is USDC or EURC only, destination is the Avalanche hub action.
- Hyperlane lane: source asset is AUDF/JPYC/MXNB/KRW1/ZCHF, destination is
  either "receive on hub" or "receive into ICA and execute hub action".
- For Hyperlane, quote route fees immediately before transfer using
  `quoteTransferRemote(destination, recipient, amount)`.
- For Hyperlane intent messages, quote with `quoteIntent(...)`, submit with
  `sendIntent(...)`, then use `executeIntent(intentId)` for beneficiary-pulled
  actions or `executeRoutedIntent(intentId)` for allowlisted route-delivered
  actions.
- The `_amount` in `transferRemote` is exact amount out; the approval may need
  more than `_amount` when route token fees exist.
- Use `hyperlaneAddressToBytes32` from the SDK for EVM recipients.
- Hide a route until its `status` is `deployed` and a route token address exists.

## 8. Open implementation work

- Deploy Arc Testnet Hyperlane core from `hyperlane/arc-testnet/core-config.yaml`
  and hand the resulting `addresses.yaml` to Circle for relayer maintenance.
- Deploy Fuji mock stablecoins for the non-EURC basket on selected origin
  testnets.
- Deploy Fuji-bound HWRs and commit route artifacts.
- Decide whether Fuji transfer-and-call needs a local ICA router deployment or
  starts as a two-step UX.
- Extend the Tenderly smoke matrix to include a Hyperlane-arrived token path once
  vnet route contracts exist.
