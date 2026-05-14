# fx-Telaraña — Contracts

Phase 0 Solidity for the fx-Telaraña Hub-and-Spoke protocol on Arc.
Spec: `../docs/SPEC.md` (v0.2).

## Layout

```
contracts/
├── foundry.toml
├── remappings.txt
├── .env.example                       # Arc testnet addresses + Pyth feed ids pre-filled
├── src/
│   ├── interfaces/
│   │   ├── IFxOracle.sol
│   │   ├── IFxMarketRegistry.sol
│   │   ├── IFxSpoke.sol
│   │   ├── IFxHubMessageReceiver.sol
│   │   └── ICctp.sol                  # local 0.8.26 redeclaration of Circle V2 surfaces
│   ├── libraries/
│   │   └── CctpMessageLib.sol         # CCTP V2 outer + burn body byte decoder
│   ├── hub/
│   │   ├── FxOracle.sol               # Pyth primary + RedStone secondary; 24/7
│   │   ├── MorphoOracleAdapter.sol    # IFxOracle → Morpho Blue IOracle(price())
│   │   ├── FxMarketRegistry.sol       # Single surface over Morpho Blue isolated markets
│   │   ├── FxReceipt.sol              # ERC-4626 wrapping a Morpho supply position
│   │   ├── FxLiquidator.sol           # Permissionless keeper wrapper around Morpho.liquidate
│   │   └── FxHubMessageReceiver.sol   # CCTP V2 inbound + executor + stranded-deposit sweep
│   └── spoke/
│       └── FxSpoke.sol                # CCTP V2 depositForBurnWithHook on each spoke chain
├── script/
│   ├── DeployFxHub.s.sol              # full Arc-side stack
│   └── DeployFxSpoke.s.sol            # per-spoke deploy (Ethereum, Base)
└── test/
    ├── FxOracle.t.sol                 # 12 unit tests (mock Pyth)
    ├── FxHubMessageReceiver.t.sol     # 10 unit tests (mock CCTP MessageTransmitter)
    ├── FxSpoke.t.sol                  # 5 unit tests (mock CCTP TokenMessenger)
    ├── MainnetFork.t.sol              # 4 fork tests against Morpho Blue on Ethereum mainnet
    └── mocks/  utils/
```

## Build + test

```bash
forge build

# Unit tests only (fast)
forge test --no-match-contract MainnetForkTest

# Full suite incl. mainnet fork tests against real Morpho Blue
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test
```

Current status: **31 / 31 tests passing.**

## Phase 0 decisions (spec v0.2)

| ID | Decision | Where in code |
|---|---|---|
| D1 | Morpho Blue substrate, two isolated markets | `FxMarketRegistry.sol`, `MorphoOracleAdapter.sol` |
| D2 | Pasillo proxies Bufi-KYC → Hinkal AccessToken | Off-chain (Phase 1) |
| D3 | Pyth primary + RedStone secondary, both permissionless | `FxOracle.sol` (RedStone consumer extraction = Phase 0.5) |
| D4 | Fresh SCA per deposit; Phase 0 = public-only first | `FxHubMessageReceiver.sol` accepts any `beneficiary` |

## Implementation guardrails enforced

- `IFxOracle` is the only price-read surface. Pool, hook, liquidator, frontend never call Pyth/RedStone SDK directly.
- `IFxSpoke.enterHub(token, amount, beneficiary, hubCalldata)` takes explicit `beneficiary` (NEVER `msg.sender`-derived) — confidential-mode flows pass the user's fresh SCA, public mode passes the EOA/SCA.
- `FxHubMessageReceiver.sweepStrandedDeposit(messageNonce)` recovers funds after a 24h grace window when the hub-call reverted on a CCTP-mint hook.
- All Solidity 0.8.26, optimizer 1M runs, `via_ir`, `cancun` EVM.

## Verified Arc testnet addresses

Pre-filled in `.env.example`:

| Contract | Address |
|---|---|
| USDC (native gas) | `0x3600000000000000000000000000000000000000` |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| Pyth | `0x2880aB155794e7179c9eE2e38200202908C17B43` |
| CCTP V2 TokenMessenger | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| CCTP V2 MessageTransmitter | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` |
| CCTP domain | `26` |

Pyth feed ids (verified via Hermes):
- USDC/USD: `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a`
- EURC/USD: `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c`
- EUR/USD: `0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b`

## Deferred to later phases

- **Phase 0.5** — RedStone consumer payload extraction in `FxOracle.getMidWithUpdate` (currently the RedStone path is a stable ABI placeholder; deviation gate works once `_setRedstoneCacheForTest` is replaced with the real consumer wiring).
- **Phase 1** — Hinkal Emporium wrappers in `@bu/private-transfer-core` + fresh-SCA-per-deposit factory integration; auto-routing on AccessToken presence.
- **Phase 2** — `FxSwapHook.sol` (Uniswap v4 hook with oracle-anchored PMM + JIT-borrow from Morpho).

## Deploy

```bash
# Arc testnet (Hub-side)
cp .env.example .env && edit  # fill ARC_MORPHO_BLUE + ARC_MORPHO_ADAPTIVE_IRM + DEPLOYER_PRIVATE_KEY + FX_HUB_LLTV
forge script script/DeployFxHub.s.sol --rpc-url arc_testnet --broadcast --verify

# Per-spoke (Ethereum / Base)
SPOKE_USDC=... SPOKE_CCTP_TOKEN_MESSENGER=... ARC_HUB_RECEIVER=... ARC_DOMAIN=26 \
  forge script script/DeployFxSpoke.s.sol --rpc-url ethereum --broadcast --verify
```
