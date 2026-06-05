# Repair FxOracleV2 JPYC + cirBTC Feeds

This runbook prepares the Arc Testnet repair for the live `FxOracleV2`
feed table. No broadcast is performed by this document.

## Target

- Chain: Arc Testnet (`5042002`)
- Oracle: `0xdA5Cd65521B64A7375C8d63EeDe52347783cEd74`
- Admin / keeper: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`
- JPYC: `0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29`
- cirBTC: `0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF`

## Feed Config

- JPYC uses Pyth `JPY/USD`
  `0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52`
  with `inverted=true`.
- cirBTC uses Pyth `BTC/USD`
  `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`
  with `inverted=false`.

The live `contracts/script/pyth-fx-pusher.sh` default feed set must include
both feed ids before the repair is broadcast, otherwise `getMid()` can still
revert after the oracle table is fixed.

## Safety Gates

- Do not broadcast from Codex.
- Use the admin private key for
  `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`; the script rejects any
  other signer.
- Confirm the signer still has `DEFAULT_ADMIN_ROLE` on the oracle.
- Confirm the RPC reports Arc chain id `5042002`.
- Start or update the Pyth pusher so `JPY/USD` and `BTC/USD` stay fresh.

## Dry Run

```bash
cd contracts

FX_ORACLE_V2_ADMIN_PRIVATE_KEY="$FX_ORACLE_V2_ADMIN_PRIVATE_KEY" \
CONFIRM_FX_ORACLE_V2_REPAIR=SET_JPYC_AND_CIRBTC_PYTH_FEEDS_ON_ARC \
FX_ORACLE_V2=0xdA5Cd65521B64A7375C8d63EeDe52347783cEd74 \
forge script script/RepairFxOracleV2Feeds.s.sol:RepairFxOracleV2Feeds \
  --rpc-url "$ARC_RPC_URL" \
  -vvvv
```

Expected readback:

- `JPYC after` feed equals the JPY/USD id above and `inverted` is `true`.
- `cirBTC after` feed equals the BTC/USD id above and `inverted` is `false`.

## Pyth Pusher

```bash
cd contracts/script

ARC_RPC_URL="$ARC_RPC_URL" \
PYTH_PUSHER_PRIVATE_KEY="$PYTH_PUSHER_PRIVATE_KEY" \
./pyth-fx-pusher.sh
```

The default pusher feed list now includes USDC/USD, EURC/USD, AUD/USD,
JPY/USD, USD/MXN, and BTC/USD. Use `PYTH_FEEDS` only when intentionally
overriding this full Arc default set.

## Broadcast Gate

Only after explicit approval, run the dry-run command with `--broadcast`.
Keep the same confirmation string and the same admin key:

```bash
forge script script/RepairFxOracleV2Feeds.s.sol:RepairFxOracleV2Feeds \
  --rpc-url "$ARC_RPC_URL" \
  --broadcast \
  -vvvv
```

Post-broadcast, rerun the dry run and confirm the readback values remain
unchanged while the pusher is active.
