# RFQ Pasillo

RFQ Pasillo is a future quote corridor for Telaraña spot FX execution.

Telaraña is an onchain FX liquidity web for Avalanche stablecoin markets. RFQ
Pasillo prepares a path where a whitelisted requester can ask for a quote before
settling an FX request through Telaraña.

Future whitelisted trading frontends such as BuFX may route requests through
Telaraña. This document does not define or implement BuFX.

## Scope

This branch prepares only:

- TypeScript request and quote types in `packages/sdk/src/rfq-pasillo.ts`.
- Solidity placeholder interface in `contracts/src/interfaces/ITelaranaRfqPasillo.sol`.
- Indexer-ready event names and field schemas.
- Frontend handoff language for future request intake.

This branch does not build:

- RFQ matching engine.
- Market maker system.
- Settlement logic.
- Uniswap v4 hook.
- Any derivatives or leveraged trading system.

## Request Shape

`RfqQuoteRequest`:

- `quoteRequestId`
- `requester`
- `tokenIn`
- `tokenOut`
- `amountIn`
- `routeId`
- `recipient`
- `deadline`
- `metadataRef`

`RfqQuote`:

- `quoteId`
- `quoteRequestId`
- `maker`
- `amountOut`
- `validUntil`
- `settlementTarget`
- `metadataRef`

## Event Schema

Indexers should prepare for these event names:

- `RfqQuoteRequested`
- `RfqQuoteAccepted`
- `RfqQuoteFilled`

The SDK exports `RFQ_PASILLO_EVENT_NAMES` and `RFQ_PASILLO_INDEXER_SCHEMA` as
the frontend/indexer schema source of truth.

## Whitelisted Requesters

RFQ Pasillo is not public intake by default. The intended requester classes are:

- `internal`
- `bufx`
- `rfq-pasillo`
- `partner`

Requester allowlisting is represented by the future Telaraña spot FX interface
and SDK types. The first live requester should be an internal test requester.

## Handoff Notes

Frontend work should display RFQ Pasillo as a future corridor only. Do not expose
quote request actions unless the deployed manifest includes an RFQ Pasillo
contract address, allowlist state, and route configuration.
