# Relayer-API deploy (Railway) — testnet

Hosts `relayer-api` (the stateless meta-tx submitter) so ghost withdrawals route
through the relayer (relayer = on-chain `msg.sender`, user EOA never appears).
The MCP reads `GHOST_RELAYER_URL`; once this is live + that env is set,
`relayerSubmission.available` flips `true`.

**Not deployed here: `asp-postman`.** It is single-writer and owned by the
`ASP_POSTMAN` role holder (deployer EOA `0x0646FFe1…`). Running a second postman
clobbers the merkle root (see README). Keep exactly one, where it already runs.

## What's in the repo
- `packages/relayer-privacy/Dockerfile` — Bun monorepo build (context = repo root):
  `bun install` → build `@bu/fx-engine` → run `relayer-api`. Maps Railway `PORT` → `RELAYER_PORT`.
- `.dockerignore` (repo root) — excludes `contracts/`, `.git`, `node_modules`, `dist`, secrets.

## Env (Railway service `bufi-relayer`)
| var | value | notes |
|---|---|---|
| `PRIVATE_KEY` | funded Arc EOA key | **SECRET — you set this.** Gas = USDC on Arc. Any funded EOA (no role needed). |
| `RPC_URL` | `https://rpc.drpc.testnet.arc.network` | |
| `ENTRYPOINT_ADDRESS` | `0xD11cDdd1f04e850d3810a71608A49907c80f2736` | live FxPrivacyEntrypoint (Arc) |
| `RELAYER_MAX_FEE_BPS` | `500` | |
| `RELAYER_RATE_LIMIT_PER_MIN` | `60` | |
| `DRY_RUN` | `false` | set `true` to accept + validate without broadcasting |
| `RAILWAY_DOCKERFILE_PATH` | `packages/relayer-privacy/Dockerfile` | tells Railway which Dockerfile |

## Deploy
```bash
cd fx-telarana
railway init --name bufi-relayer            # one-time
railway variables set RAILWAY_DOCKERFILE_PATH=packages/relayer-privacy/Dockerfile \
  RPC_URL=https://rpc.drpc.testnet.arc.network \
  ENTRYPOINT_ADDRESS=0xD11cDdd1f04e850d3810a71608A49907c80f2736 \
  RELAYER_MAX_FEE_BPS=500 RELAYER_RATE_LIMIT_PER_MIN=60 DRY_RUN=false
# you: set the funded key
railway variables set PRIVATE_KEY=0x<funded-arc-eoa-key>
railway up -c                                # build + deploy
railway domain                               # public URL, e.g. https://bufi-relayer-xxxx.up.railway.app
curl -s https://<domain>/health              # { ok:true, entrypoint, dryRun, maxRelayFeeBPS }
```

## Wire the MCP (defi-web-app)
```bash
# on the bufi-hyper-mcp Railway service:
railway variables set GHOST_RELAYER_URL=https://<bufi-relayer-domain> -s bufi-hyper-mcp
# redeploy MCP; then verify cross-currency/relay show available:true
curl -s https://mcp.bu.finance/api/ghost/swap -XPOST -H 'content-type: application/json' \
  -d '{"from":"USDC","to":"EURC","amount":"100","trader":"0x..."}' | jq .relayerSubmission.available
```

## Split-operator privacy note
For true depositor↔recipient unlinkability the relayer should be a *different*
operator than the deposit-advice MCP. Co-hosting on one Railway account is
acceptable for testnet but is the single-operator correlation risk the
`privacyNotice` discloses — note it before mainnet.
