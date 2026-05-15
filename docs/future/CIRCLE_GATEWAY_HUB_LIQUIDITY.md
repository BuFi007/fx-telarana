# Circle Gateway Hub Liquidity

Circle Gateway is the planned fast USDC rail for Telaraña hub-to-hub liquidity.
Gateway is USDC-only in the current design. CCTP is used only for
Circle-supported USDC/EURC spoke entry. Hyperlane and approved issuer-specific
routes handle other stablecoin transport and cross-chain intent messages.
Gateway is used here for USDC liquidity movement between hubs, starting with
Fuji and Arc Testnet.

## Scope

Current branch prepares config, typed data, ABI helpers, and the first
`TelaranaGatewayHubHook`. It does not execute production swaps.

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
6. On the destination hub chain, call `TelaranaGatewayHubHook.receiveGatewayMint(...)`.
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
- `TelaranaGatewayHubHookAbi`
- `GATEWAY_EIP712_DOMAIN`
- `GATEWAY_EIP712_TYPES`
- `TELARANA_GATEWAY_TESTNET_CHAINS`
- `TELARANA_GATEWAY_HUB_ROUTES`
- `GATEWAY_HUB_ACTION_IDS`
- `GATEWAY_HUB_EVENT_NAMES`
- `GATEWAY_HUB_INDEXER_SCHEMA`
- `GatewayHubMintContext`
- `buildGatewayBurnIntent`
- `gatewayBurnIntentToJson`
- `encodeGatewayMintCalldata`
- `evmAddressToGatewayBytes32`

Do not reorder or rename the Gateway EIP-712 fields. The SDK tests lock the
exact Circle field order.

## Contract Preparation

Solidity surfaces are prepared at:

- `contracts/src/interfaces/ICircleGateway.sol`
- `contracts/src/interfaces/ITelaranaGatewayHubHook.sol`
- `contracts/src/hub/TelaranaGatewayHubHook.sol`

The hook currently validates:

- route id is enabled,
- destination Gateway Minter matches the configured route,
- destination USDC matches the configured route,
- caller is whitelisted for the route,
- destination hub action is enabled,
- received USDC balance delta matches the expected amount,
- request id has not been used before.

The next implementation step is to decode or verify Gateway `hookData` /
attestation context before opening this beyond the trusted executor path.
Until then, `receiveGatewayMint(...)` is intentionally `EXECUTOR_ROLE` gated.
