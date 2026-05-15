# Circle Gateway Hub Liquidity

Circle Gateway is the planned fast USDC rail for Telaraña hub-to-hub liquidity.
CCTP stays the canonical USDC/EURC spoke-entry path. Hyperlane stays the
permissionless route for non-Circle assets and cross-chain intents. Gateway is
used here for USDC liquidity movement between hubs, starting with Fuji and Arc
Testnet.

## Scope

Current branch prepares config, typed data, ABI helpers, and interface stubs.
It does not deploy a Gateway hook or execute production swaps.

Near-term testnet topology:

| Hub | Chain id | Gateway domain | USDC |
|---|---:|---:|---|
| Avalanche Fuji | `43113` | `1` | `0x5425890298aed601595a70AB815c96711a31Bc65` |
| Arc Testnet | `5042002` | `26` | `0x3600000000000000000000000000000000000000` |

Circle Gateway testnet contracts:

| Contract | Address |
|---|---|
| Gateway Wallet | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| Gateway Minter | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` |
| API | `https://gateway-api-testnet.circle.com/v1` |

## Hub-To-Hub Flow

1. Deposit USDC into Gateway Wallet on the source hub chain.
2. Build a Circle Gateway `BurnIntent` from `TELARANA_GATEWAY_HUB_ROUTES`.
3. Have the current source signer EOA sign the Gateway EIP-712 payload.
4. Submit the signed burn intent to Circle Gateway API.
5. Receive attestation payload and API signature.
6. On the destination hub chain, call Gateway Minter or a future
   Telaraña Gateway hook that wraps `gatewayMint(...)`.
7. Use the minted USDC for the destination hub action: mint-to-hub first,
   then later mint-and-request-spot-FX when the spot route is deployed.

## Signer Mode

Current signer mode is `eoa`. The SDK also models
`erc1271-contract-future`, but frontends must keep that path disabled until
Circle's contract-signing support is published and the relevant contract signer
is allowlisted.

## SDK Exports

Use these SDK exports from `@bu/fx-engine`:

- `CircleGatewayWalletAbi`
- `CircleGatewayMinterAbi`
- `GATEWAY_EIP712_DOMAIN`
- `GATEWAY_EIP712_TYPES`
- `TELARANA_GATEWAY_TESTNET_CHAINS`
- `TELARANA_GATEWAY_HUB_ROUTES`
- `GATEWAY_HUB_EVENT_NAMES`
- `GATEWAY_HUB_INDEXER_SCHEMA`
- `buildGatewayBurnIntent`
- `gatewayBurnIntentToJson`
- `encodeGatewayMintCalldata`
- `evmAddressToGatewayBytes32`

Do not reorder or rename the Gateway EIP-712 fields. The SDK tests lock the
exact Circle field order.

## Contract Preparation

Solidity interfaces are prepared at:

- `contracts/src/interfaces/ICircleGateway.sol`
- `contracts/src/interfaces/ITelaranaGatewayHubHook.sol`

The future implementation should validate:

- route id is enabled,
- source and destination Gateway domains match the configured route,
- source and destination USDC match the configured route,
- caller is whitelisted for the route,
- destination hub action is enabled,
- received USDC balance delta matches the expected amount,
- downstream spot FX route is live before any atomic FX action.

