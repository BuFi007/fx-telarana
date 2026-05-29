# syntax=docker/dockerfile:1
# Relayer-API for the fx-Telaraña Privacy Hook (testnet only). Stateless meta-tx
# submitter: receives client-side Groth16 withdrawal proofs and broadcasts
# relay() / relayCrossCurrency() so the RELAYER (not the user's wallet) is the
# on-chain msg.sender — the privacy fix. No SQLite, no role required (anyone may
# submit a valid proof). The asp-postman is NOT run here — it is single-writer
# and owned by the ASP_POSTMAN role holder (see packages/relayer-privacy/README.md).
#
# Build context = repo ROOT (Bun monorepo). See .dockerignore.
# Deploy: Railway service "bufi-relayer". Required runtime env:
#   PRIVATE_KEY         funded Arc EOA (gas = USDC) — set as a Railway SECRET
#   RPC_URL             https://rpc.drpc.testnet.arc.network
#   ENTRYPOINT_ADDRESS  0xD11cDdd1f04e850d3810a71608A49907c80f2736
#   RELAYER_MAX_FEE_BPS 500   RELAYER_RATE_LIMIT_PER_MIN 60   DRY_RUN false
# Railway injects PORT at runtime; the entrypoint maps it to RELAYER_PORT.
FROM oven/bun:1.3.10
WORKDIR /app

COPY . .

# Install workspace deps and build @bu/fx-engine — relayer-api imports
# "@bu/fx-engine/privacy", which resolves to packages/sdk/dist/privacy/index.js.
RUN bun install && bun run --cwd packages/sdk build

ENV RELAYER_PORT=8787
EXPOSE 8787
# relayer-api reads RELAYER_PORT; Railway provides PORT. Map them, exec for signals.
CMD ["sh", "-c", "RELAYER_PORT=${PORT:-8787} exec bun run --cwd packages/relayer-privacy relayer-api"]
