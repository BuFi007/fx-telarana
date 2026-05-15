# Frontend Integration Prompt — fx-Telarana Avalanche Hub

Use this prompt with the front-end developer or agent that will integrate the
protocol into the app. Source repo:

- Local: `/Users/criptopoeta/coding-dojo/fx-onchain`
- Remote: `https://github.com/BuFi007/fx-telarana`
- SDK package in repo: `packages/sdk`
- Source of truth for deployed addresses: `deployments/*.json`
- Non-USDC asset spoke architecture: `docs/HYPERLANE_ASSET_SPOKES.md`

## Prompt

You are integrating the fx-Telarana onchain FX credit protocol into our app.
Use Bufi Wallet for Ghost Mode and viem for reads/writes. Public mode can still
support Dynamic or another EVM connector if the app wants broader wallet access.
The product lets a user connect a wallet, deposit USDC or supported stablecoins,
lend/borrow through Morpho-backed isolated markets, and swap through fx-Telarana
Uniswap v4 hooks when hook addresses are available.

Build a testing UI first, not marketing pages. The first screen should be an
operator/testing console with chain selector, wallet state, Bufi Wallet pass
state, balances, market cards, approval state, lend/borrow/repay/withdraw forms,
cross-chain spoke entry, Ghost Mode route state, and swap/quote panels.

## Current Testing Hub

Primary test hub is Avalanche Fuji.

Native gas token: AVAX. There is no ERC-20 AVAX contract involved in protocol
calls; users only need AVAX for gas on Avalanche/Fuji.

Avalanche Fuji hub:

| Item | Address |
|---|---|
| Chain id | `43113` |
| Deployer | `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` |
| FxOracle | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` |
| FxMarketRegistry | `0x7ba745b979e027992ecfa51207666e3f5b46cf0a` |
| FxLiquidator | `0x2900599ff0e6dd057493d62fac856e5a8f93c6eb` |
| FxHubMessageReceiver | `0x365DE300dDa61C81a33bcE3606A5d524eD964362` |
| MorphoBlue | `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6` |
| IrmMock | `0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA` |
| Pyth | `0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509` |
| CCTP TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| CCTP MessageTransmitterV2 | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` |
| CCTP domain | `1` |
| USDC | `0x5425890298aed601595a70AB815c96711a31Bc65` |
| Circle EURC | `0x5E44db7996c682E92a960b65AC713a54AD815c6B` |
| Legacy MockEURC | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` |
| FxReceiptEURC | `0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2` |
| FxReceiptUSDC | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` |

Fuji market ids:

| Market | Meaning | Market id |
|---|---|---|
| M1 | loan `EURC`, collateral `USDC` | `0x7d99088a9fe61331c49a92eb16fa3794b0bc2862b211f5a70f31a64cef25029e` |
| M2 | loan `USDC`, collateral `EURC` | `0x1700104cf29eceb113e01a1bcdc913e5e10d3d37314cee235752aa88bf153197` |

The live Fuji hub was originally deployed against the legacy mock. The deploy
script now defaults to Circle Fuji EURC. Do not label real EURC markets active
until the new deployment manifest contains the Circle EURC address and matching
market ids.

Same-chain hub UX should call `FxMarketRegistry` directly. Do not route a Fuji
hub user through the Fuji `FxSpoke` unless explicitly testing CCTP self-loop
behavior.

## Current Spokes To Avalanche Fuji Hub

The currently listed deployed spokes burn USDC via CCTP V2 and target the Fuji hub receiver
`0x365de300dda61c81a33bce3606a5d524ed964362` with hub CCTP domain `1`.
EURC uses the same Circle-only CCTP lane only on chains where Circle has
published EURC and the matching spoke/manifest entry exists.

| Spoke chain | Chain id | FxSpoke | Spoke USDC | Spoke CCTP domain |
|---|---:|---|---|---:|
| Avalanche Fuji self-loop | `43113` | `0xAa875a68b0155da4bD6A528ee9e1137017D18b41` | `0x5425890298aed601595a70AB815c96711a31Bc65` | `1` |
| Ethereum Sepolia | `11155111` | `0xdabf610c279d900b40ca4df62f1e86cc2d0a4fd4` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | `0` |
| Arbitrum Sepolia | `421614` | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` | `3` |
| OP Sepolia | `11155420` | `0xef64621d41093144d9ed8ab8327ee381ecdb79e6` | `0x5fd84259d66Cd46123540766Be93DFE6D43130D7` | `2` |
| Polygon Amoy | `80002` | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` | `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582` | `7` |
| Unichain Sepolia | `1301` | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` | `0x31d0220469e10c4E71834a79b1f276d740d3768F` | `10` |
| World Chain Sepolia | `4801` | `0xef64621d41093144d9ed8ab8327ee381ecdb79e6` | `0x66145f38cBAC35Ca6F1Dfb4914dF98F1614aeA88` | `14` |
| Arc Testnet | `5042002` | `0x729fe51fa88eae24cbcff7a192c5a91e937ceb68` | `0x3600000000000000000000000000000000000000` | `26` |

Use the deployment manifests above over `packages/sdk/src/addresses/index.ts`
for migrated spoke addresses until the SDK registry is refreshed.

## Mainnet Target Assets On Avalanche

These are the production basket assets for Avalanche C-Chain. Do not display
BRLA or PHPC as supported in Phase 3.

| Asset | Address | Decimals | Status |
|---|---|---:|---|
| USDC | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` | 6 | issuer |
| AUDF | `0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b` | 6 | issuer |
| JPYC | `0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB` | 18 | issuer |
| MXNB | `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA` | 6 | issuer |
| KRW1 | `0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318` | 0 | issuer |
| ZCHF | `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` | 18 | issuer, CCIP-bridged |
| EURC | `0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD` | 6 | Circle issuer |
| BRLA | n/a | 18 | excluded: not natively live on Avalanche |
| PHPC | n/a | 6 | excluded: not natively live on Avalanche |

Pyth feed ids:

| Asset | Pyth feed | Inverted |
|---|---|---|
| USDC/USD | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | false |
| EURC/USD | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | false |
| EUR/USD | `0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b` | false |
| AUD/USD | `0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80` | false |
| USD/JPY | `0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52` | true |
| USD/KRW | `0xe539120487c29b4defdf9a53d337316ea022a2688978a468f9efd847201be7e3` | true |
| USD/MXN | `0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca` | true |
| USD/CHF | `0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8` | true |

RedStone feed ids: `USDC`, `EURC`, `AUD`, `JPY`, `KRW`, `MXN`, `CHF`.

## Contract Surfaces To Integrate

Use the typed ABIs exported from `@bu/fx-engine`:

- `FxMarketRegistryAbi`
- `FxSpokeAbi`
- `FxOracleAbi`
- `FxSwapHookAbi`
- `FxReceiptAbi`
- `FxLiquidatorAbi`
- `FxHubMessageReceiverAbi`
- `FxSpokeIntentRouterAbi`
- `FxHyperlaneHubReceiverAbi`
- `HyperlaneWarpRouteAbi`
- `HyperlaneInterchainAccountRouterAbi`
- `IBufiKycPassAbi`

Ghost Mode is not a third-party privacy wallet and not Circle Wallet. It is a
Bufi Wallet KYC/KYB-pass route that will use privacy hooks/routers. For now,
wire the UI to the SDK route mode and eligibility types, then hide Ghost actions
until the matching Ghost contracts are deployed.

Planned Ghost Mode contracts:

- `IBufiKycPass` verifier
- `FxGhostRouter`
- `FxGhostCommitmentRegistry`
- `FxGhostSwapHook`
- `FxGhostWithdrawalRouter`

Ghost Mode UI checks:

- connected wallet is Bufi Wallet,
- pass status is valid KYC or KYB,
- selected action has a deployed Ghost route/hook,
- selected market is live,
- proof generation succeeds,
- fallback public mode is shown with exact `EligibilityReason` when unavailable.

For Morpho authorization, use this minimal ABI:

```ts
export const MorphoAuthAbi = [
  {
    type: "function",
    name: "setAuthorization",
    stateMutability: "nonpayable",
    inputs: [
      { name: "authorized", type: "address" },
      { name: "newIsAuthorized", type: "bool" },
    ],
    outputs: [],
  },
] as const;
```

Core registry calls:

```ts
supply(loanToken, collateralToken, assets, onBehalf)
withdraw(loanToken, collateralToken, shares, onBehalf, receiver)
supplyCollateral(loanToken, collateralToken, collateral, onBehalf)
withdrawCollateral(loanToken, collateralToken, collateral, onBehalf, receiver)
borrow(loanToken, collateralToken, assets, onBehalf, receiver)
repay(loanToken, collateralToken, assets, onBehalf)
listPools()
paramsOf(loanToken, collateralToken)
isPoolLive(loanToken, collateralToken)
```

Important: before using `FxMarketRegistry` on behalf of a user, ask the user to
call `MorphoBlue.setAuthorization(FxMarketRegistry, true)` once per wallet on
the hub chain. Also ask for ERC-20 approvals to `FxMarketRegistry` for tokens
that will be pulled by `supply`, `supplyCollateral`, or `repay`.

Cross-chain entry:

```ts
FxSpoke.enterHub(token, amount, beneficiary, hubCalldata)
```

- `token` should be spoke-chain USDC or EURC only. CCTP is not a path for
  AUDF/JPYC/MXNB/KRW1/ZCHF or other non-Circle stablecoins.
- `amount` is raw token units on the spoke chain.
- `beneficiary` must be the user's hub-chain EVM address.
- `hubCalldata` is ABI-encoded `FxMarketRegistry` calldata, usually built by
  `planSupply`, `planSupplyCollateral`, or `planRepay` from `packages/sdk`.
- If the hub execution reverts after CCTP mint, the hub marks the deposit as
  stranded; recovery is via `FxHubMessageReceiver.sweepStrandedDeposit(...)`
  after the configured grace window.

Non-USDC asset spokes:

- Use Hyperlane Warp Routes plus the Hyperlane intent lane for
  AUDF/JPYC/MXNB/KRW1/ZCHF when the user starts on a non-hub chain. Keep
  `FxSpoke` for CCTP USDC/EURC only.
- Read `addresses[chainId].hyperlane` from the SDK for Hyperlane domain,
  Mailbox, Interchain Gas Paymaster if present, ICA router, and app-specific
  ISM addresses.
- Arc Testnet Hyperlane core is deployed at Mailbox
  `0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9`; its bootstrap
  `interchainGasPaymaster` is `0x0`, so the relayer is directly funded rather
  than origin-fee funded.
- Fuji hub receivers that accept Arc-origin Hyperlane intents must expose
  app-specific ISM `0x3f5d9B44aa1D59D26B20862D91533d60B32d9aFa` through
  `interchainSecurityModule()`.
- Hide any Hyperlane route until `hyperlaneWarpRoutes[].status === "deployed"`
  and route token addresses are present in the deployment manifest.
- For a route/market/action intent, call
  `FxSpokeIntentRouter.quoteIntent(...)`, then
  `FxSpokeIntentRouter.sendIntent{value: fee}(action, beneficiary, inputToken,
  inputAmount, loanToken, collateralToken, route)`. The SDK exports
  `planFxSpokeIntent`, `planExecuteHyperlaneIntent`, and `FxHyperlaneAction`.
- After the routed asset is available on the hub and the user has approved
  `FxHyperlaneHubReceiver`, call `executeIntent(intentId)`. First-pass
  executable actions are `Supply`, `SupplyCollateral`, and `Repay`; `Borrow`
  intents are accepted for coordination but execution is blocked until registry
  delegation is designed.
- For a route transfer, quote fees immediately before transfer using
  `quoteTransferRemote(destinationDomain, recipientBytes32, amount)`, then call
  `transferRemote(destinationDomain, recipientBytes32, amount)` on the route
  contract. The SDK exports `HyperlaneWarpRouteAbi`,
  `planHyperlaneWarpTransferRemote`, and `hyperlaneAddressToBytes32`.
- For one-click bridge-then-action, use Hyperlane Interchain Accounts only after
  route testing. If the ICA executes `FxMarketRegistry`, the Morpho position is
  owned by the ICA because protected registry calls require
  `onBehalf == msg.sender`.
- Treat `hubTokenSource === "hyperlaneSynthetic"` as a separate asset from the
  issuer token. It needs its own market ids, caps, labels, and monitoring.

Swaps:

- `FxSwapHook.quoteExactInput(sellToken, sellAmount)` returns `(buyAmount, oraclePriceE18)`.
- LP testing: approve both pair tokens to the hook, then call
  `FxSwapHook.deposit(amount0, amount1)` and `FxSwapHook.redeem(shares)`.
- Swap execution uses Uniswap v4 PoolManager/Universal Router with pool key:
  `currency0`, `currency1`, `fee = 3000`, `tickSpacing = 60`, `hooks = FxSwapHook`.
- Avalanche basket hook addresses are produced by
  `DeployTenderlyAvalancheBasket.s.sol` into
  `deployments/tenderly-avalanche-fuji-basket.json` once Tenderly write quota
  allows the deployment. Until that manifest exists, gate swap UI behind
  "hook not deployed on this environment".

## Wallet Requirements

Use Bufi Wallet for Ghost Mode. Dynamic may be used for public EVM wallet
connection and chain switching if the existing app stack requires it, but do not
build Ghost Mode on Circle Wallet. Required chains:

- Avalanche Fuji `43113`
- Ethereum Sepolia `11155111`
- Arbitrum Sepolia `421614`
- OP Sepolia `11155420`
- Polygon Amoy `80002`
- Unichain Sepolia `1301`
- World Chain Sepolia `4801`
- Arc Testnet `5042002`

For the first testing release:

1. Detect connected chain.
2. If chain is Avalanche Fuji, show hub actions directly.
3. If chain is a spoke, show only USDC balance, USDC approval to `FxSpoke`,
   and `enterHub(...)` forms.
4. If the user selects Ghost Mode, require Bufi Wallet pass eligibility and show
   the planned Ghost route/hook status before any transaction.
5. Add a "hub destination preview" that decodes `hubCalldata` and shows the
   resulting hub action before the user burns USDC.
6. Read hub positions from Morpho/FxReceipt where possible, and always expose
   raw transaction hashes.

Use viem with Dynamic's wallet client. Example flow for hub borrow:

```ts
// 1. Ensure Morpho registry authorization on Avalanche Fuji.
await walletClient.writeContract({
  chain: avalancheFuji,
  address: "0xeF64621D41093144D9ED8aB8327eE381ECdB79E6",
  abi: MorphoAuthAbi,
  functionName: "setAuthorization",
  args: ["0x7ba745b979e027992ecfa51207666e3f5b46cf0a", true],
});

// 2. Approve collateral token to the registry.
await walletClient.writeContract({
  chain: avalancheFuji,
  address: usdc,
  abi: erc20Abi,
  functionName: "approve",
  args: ["0x7ba745b979e027992ecfa51207666e3f5b46cf0a", collateralAmount],
});

// 3. Supply collateral.
await walletClient.writeContract({
  chain: avalancheFuji,
  address: "0x7ba745b979e027992ecfa51207666e3f5b46cf0a",
  abi: FxMarketRegistryAbi,
  functionName: "supplyCollateral",
  args: [eurc, usdc, collateralAmount, userAddress],
});

// 4. Borrow the loan token.
await walletClient.writeContract({
  chain: avalancheFuji,
  address: "0x7ba745b979e027992ecfa51207666e3f5b46cf0a",
  abi: FxMarketRegistryAbi,
  functionName: "borrow",
  args: [eurc, usdc, borrowAmount, userAddress, userAddress],
});
```

Build the UI defensively:

- Disable entry-side actions when `isPoolLive` is false.
- Keep repay/withdraw enabled even if a pool is paused.
- Scale amounts by each token's decimals; KRW1 has `0` decimals.
- Do not assume every environment has swap hooks.
- Do not list excluded assets BRLA/PHPC in Phase 3.
- Treat same-chain hub actions and cross-chain spoke actions as separate modes.
