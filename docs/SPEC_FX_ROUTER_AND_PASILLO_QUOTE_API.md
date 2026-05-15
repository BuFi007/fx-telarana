# SPEC — FxRouter (Phase 2.6R) + Pasillo Quote API (Phase 3a)

**Status:** Implementation-ready spec. Hand-off to implementing agent.
**Author:** Claude, fx-Telaraña architecture review, 2026-05-14.
**Scope:** Signed-intent routing layer over the existing AMM + interop with Circle StableFX RFQ.
**Branch:** `tcxcx/fx-onchain-hub-arc` (extend in place, do not rename).
**Naming note:** `FxSwapHook.sol`'s header comment already uses the label "Phase 2.6" for its rehypothecating-PMM track. This spec uses **Phase 2.6R** ("R" for Router) to disambiguate. Resolve in `docs/TODOS.md` if you renumber.

---

## 0. Goals & non-goals

### Goals
1. Add a signed-intent EIP-712 routing layer (`FxRouter.sol`) on top of `FxSwapHook` so off-chain quoters (Pasillo, StableFX RFQ) can deliver pre-priced trades with explicit recipient + funding commitments.
2. Schema-compatible with Circle StableFX (`FxEscrow`, Arc testnet `0x867650F5eAe8df91445971f14d89fd84F0C9a9f8`) so Pasillo institutional clients can sign one EIP-712 envelope that routes to **either** fx-Telaraña AMM or StableFX RFQ.
3. Token funding via canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) — single approval surface for institutional clients.
4. First-class smart-wallet support (EIP-1271 Safe/Argent, EIP-7702 delegated EOAs) via OZ `SignatureChecker`. This is the differentiator vs StableFX's vanilla Permit2.
5. Hinkal-wrapped confidential mode: signed `recipient` is the user's fresh per-deposit SCA — never `msg.sender`-derived.
6. Off-chain Pasillo Quote API that aggregates fx-Telaraña + StableFX into a single quote envelope.

### Non-goals (defer)
- DODO PMM curve completion (lives in `FxSwapHook.sol`, Phase 2.6/2.7).
- Maker-side flow (`makerDeliver`-style two-sided settlement). FxRouter is **taker-only** in this phase; the "maker" is the AMM. Two-sided counterparty matching is Phase 2.8+.
- Cross-chain SOR. Single-hop, single-chain (Arc/Base Sepolia). Spoke→Hub flow stays in `IFxSpoke.enterHub` and is composed by Pasillo at the *quote* layer, not in this contract.
- Net settlement (`makerNetDeliver` analog). Note interest for Phase 2.8.
- Order-cancellation registry. Use signed deadlines + uuid replay protection.

---

## 1. Source-pattern references

Implementing agent: read these *first*. Patterns are paraphrased here; the source is authoritative.

### From Sera v2 (`~/Downloads/orderbook-contract-v2-9b6708c42c6d591fc77b2ecf8421881af5ca5898`, PolyForm Noncommercial — **do not fork code, reimplement patterns only**)

1. **`SeraSOR.sol::executeIntent`** — single signed envelope, executor constructs route legs, `taker`/`recipient`/`initialDepositAmount` all committed in EIP-712 to prevent hijacking. We compress this to single-leg AMM but keep the commitment pattern.
2. **`SeraLib.sol::INTENT_TYPEHASH`** — struct layout for `IntentParams`. We replace with `FxIntent` (see §3.2).
3. **`Sera.sol::isIntentUuidUsed[user][uuid]`** — per-user UUID replay protection without global nonce contention.
4. **`SeraAdmin.sol::SlippageShare`** — 3-way slippage profit split with `BPS_DENOMINATOR = 1e14` for sub-bps fees (e.g., $0.01 on $1M).
5. **`OZ SignatureChecker.isValidSignatureNowCalldata`** — used by Sera for unified EOA + EIP-1271 verification. Copy this exactly.
6. **`ReentrancyGuardTransient`** — EIP-1153 transient locks on all entry points.
7. **`audits/2026-04-30-certik-sera-final.pdf`** — read findings list before implementing.

### From Circle StableFX

1. **`FxEscrow`** Arc testnet `0x867650F5eAe8df91445971f14d89fd84F0C9a9f8`. Read ABI directly from arcscan; mirror `TakerDetails`/`MakerDetails` field order where possible.
2. **Settlement flow:** `recordTrade(taker, takerDetails, takerSig, maker, makerDetails, makerSig)` → `takerDeliver(id, permit, sig)` → `makerDeliver(id, permit, sig)`. Both deliveries use `IPermit2.PermitTransferFrom`.
3. **Tenors:** `instant` (30 min window), `hourly` (1h), `daily` (1d). FxRouter supports `instant` only in this phase (AMM is synchronous). Field is reserved for future.
4. **10-minute signature window** after quote acceptance — mirror as default `deadline` offset in Pasillo quoter.
5. **`quoteId` + `idempotencyKey`** — copy schema for institutional ops compatibility.
6. **`makerNetDeliver`** — note for Phase 2.8.
7. **Docs (in repo):**
   - `.context/attachments/pasted_text_2026-05-14_17-32-57.txt` — StableFX overview
   - `.context/attachments/pasted_text_2026-05-14_17-33-16.txt` — Permit2 approval flow
   - `.context/attachments/pasted_text_2026-05-14_17-33-22.txt` — Technical guide
   - `.context/attachments/pasted_text_2026-05-14_17-33-31.txt` — Contract interfaces

### From fx-Telaraña (this repo)

1. **`contracts/src/interfaces/IFxSpoke.sol`** — keep `beneficiary` discipline: never `msg.sender`-derived for confidential flow.
2. **`contracts/src/interfaces/IFxOracle.sol`** — only price-read surface. `FxRouter` MUST NOT call Pyth/RedStone SDK directly.
3. **`contracts/src/hub/FxSwapHook.sol`** — the AMM `FxRouter` calls into.
4. **`contracts/foundry.toml`** — Solidity 0.8.26, `evm_version = "cancun"`. Do not change.

---

## 2. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  Pasillo API (off-chain)                                       │
│  POST /v1/quote                                                │
│    ├──> Quote fx-Telaraña AMM (read FxSwapHook reserves+oracle)│
│    ├──> Quote StableFX (Circle RFQ API, KYB-gated)             │
│    └──> Return best quote { route, signedEnvelope, expiry }    │
│                                                                 │
│  POST /v1/execute (route="fx-telarana")                        │
│    └──> Submit FxIntent + permit2 sig to FxRouter.executeIntent│
│                                                                 │
│  POST /v1/execute (route="stablefx")                           │
│    └──> Submit to Circle execution engine API                  │
└────────────────────────────────────────────────────────────────┘
                            │
                            │  (on-chain — only fx-telarana route)
                            ▼
┌────────────────────────────────────────────────────────────────┐
│  Arc Mainnet / Base Sepolia                                    │
│                                                                 │
│  Client Wallet ──approve──> Permit2 (canonical)                │
│                                  │                              │
│  Client signs FxIntent ─────┐    │                              │
│                             ▼    ▼                              │
│                         FxRouter.executeIntent(intent, sig,     │
│                                       permit, permitSig)        │
│                             │                                   │
│              SignatureChecker (EOA / 1271 / 7702)               │
│              Permit2.permitTransferFrom (USDC pull)             │
│                             │                                   │
│                             ▼                                   │
│                       FxSwapHook (AMM swap)                     │
│                             │                                   │
│                             ▼                                   │
│                    recipient (signed, not msg.sender)           │
└────────────────────────────────────────────────────────────────┘
```

---

## 3. Contract spec — `FxRouter.sol`

### 3.1 File layout

```
contracts/src/hub/FxRouter.sol            # main contract
contracts/src/interfaces/IFxRouter.sol    # external interface
contracts/src/libraries/FxRouterLib.sol   # FxIntent struct, typehash, pure helpers
contracts/test/FxRouter.t.sol             # unit + fork tests
contracts/test/FxRouter.fuzz.t.sol        # fuzz suite
contracts/test/FxRouter.eip1271.t.sol     # smart-wallet sig tests
contracts/test/FxRouter.permit2.t.sol     # Permit2 interaction tests
```

### 3.2 EIP-712 typed data

**Domain:**
```solidity
EIP712Domain {
    name:    "fx-Telarana-FxRouter",
    version: "1",
    chainId, verifyingContract
}
```

**Primary struct** (field order matters for the typehash — pin it now):

```solidity
struct FxIntent {
    address taker;              // signer, must equal SignatureChecker recovered/validated address
    address recipient;          // where buyToken lands; signed to prevent hijacking
    address sellToken;          // USDC | EURC | future local stablecoins
    address buyToken;
    uint256 sellAmount;         // exact-input amount; the amount pulled via Permit2
    uint256 minBuyAmount;       // slippage floor; revert if AMM out < this
    uint48  deadline;           // unix seconds; revert if block.timestamp > deadline
    uint48  feeBps;             // protocol fee bps, BPS_DENOMINATOR = 1e14 (sub-bps granularity)
    uint8   tenor;              // 0=instant only (this phase); 1=hourly, 2=daily reserved
    bytes32 quoteId;            // off-chain quote ID from Pasillo / StableFX, opaque on-chain
    uint256 uuid;               // per-user nonce, recorded in isIntentUuidUsed[taker][uuid]
}

bytes32 constant FX_INTENT_TYPEHASH = keccak256(
    "FxIntent(address taker,address recipient,address sellToken,address buyToken,uint256 sellAmount,uint256 minBuyAmount,uint48 deadline,uint48 feeBps,uint8 tenor,bytes32 quoteId,uint256 uuid)"
);
```

**Why these fields, in this order:**
- `taker` first — matches Sera's identity-binding pattern and StableFX's `TakerDetails` first slot.
- `recipient` separate from `taker` — required for Hinkal-wrapped flow and institutional sub-account routing.
- `sellToken/buyToken/sellAmount/minBuyAmount` — exact-input only. exactOutput is Phase 2.7+ (matches `FxSwapHook` capability).
- `deadline` as `uint48` — packs with `feeBps` and `tenor` into one 256-bit slot during hashing if compiler decides to (don't rely on it, but the size choice mirrors Sera).
- `feeBps` with `BPS_DENOMINATOR = 1e14` — Sera's sub-bps pattern. Required to handle $0.01 fee on $1M trades for institutional flow.
- `tenor` reserved — enables future async settlement without breaking signed-envelope compatibility.
- `quoteId` opaque — Pasillo / StableFX bind their quote to the on-chain trade for audit/recon.
- `uuid` not chain-seq nonce — avoids global nonce contention; matches Sera's `isIntentUuidUsed`.

**Library location:** define struct + typehash + `hashIntent(FxIntent calldata)` in `libraries/FxRouterLib.sol` so off-chain TS SDK can mirror via abigen.

### 3.3 External interface

```solidity
interface IFxRouter {
    // ============ Errors ============
    error IntentExpired();
    error InvalidSignature();
    error UuidAlreadyUsed();
    error UnsupportedTenor(uint8 tenor);
    error UnsupportedPair(address sellToken, address buyToken);
    error SellAmountMismatch(uint256 intent, uint256 permit);
    error InsufficientOutput(uint256 received, uint256 minRequired);
    error RecipientZero();
    error TakerZero();
    error FeeBpsTooHigh(uint48 feeBps);
    error PausedRouter();

    // ============ Events ============
    event IntentExecuted(
        bytes32 indexed intentHash,
        address indexed taker,
        address indexed recipient,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint256 protocolFee,
        bytes32 quoteId
    );
    event ProtocolFeeCollected(address indexed token, uint256 amount);
    event Paused(bool isPaused);
    event TreasurySet(address indexed treasury);
    event MaxFeeBpsSet(uint48 maxFeeBps);

    // ============ Entry ============
    /// @notice Execute a signed FxIntent: pull sellToken via Permit2, swap through
    ///         FxSwapHook, deliver buyToken to intent.recipient.
    /// @param intent          User-signed FxIntent.
    /// @param intentSig       65-byte ECDSA or EIP-1271/7702 sig over intent EIP-712 hash.
    /// @param permit          Permit2 PermitTransferFrom for sellToken pull.
    /// @param permitSig       Permit2 signature.
    /// @return buyAmount      Actual buyToken delivered to recipient (post-fee, post-AMM).
    function executeIntent(
        FxIntent calldata intent,
        bytes calldata intentSig,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata permitSig
    ) external returns (uint256 buyAmount);

    // ============ Views ============
    function hashIntent(FxIntent calldata intent) external view returns (bytes32);
    function isIntentUuidUsed(address taker, uint256 uuid) external view returns (bool);
    function isPairSupported(address sellToken, address buyToken) external view returns (bool);
    function quoteExactInput(address sellToken, address buyToken, uint256 sellAmount)
        external view returns (uint256 expectedBuyAmount);

    // ============ Admin (timelock-gated post-deploy) ============
    function setTreasury(address) external;
    function setMaxFeeBps(uint48) external;
    function setPairAllowed(address sellToken, address buyToken, bool allowed) external;
    function pause(bool) external;
}
```

### 3.4 Storage

```solidity
contract FxRouter is EIP712, AccessControl, ReentrancyGuardTransient, IFxRouter {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BPS_DENOMINATOR = 1e14;          // Sera convention
    uint48  public constant MAX_FEE_BPS_HARD_CAP = 1e12;     // 1% absolute cap (1e12 / 1e14)
    uint8   public constant TENOR_INSTANT = 0;
    uint256 public constant MAX_DEADLINE_FUTURE = 1 hours;   // reject "stale-signed-far-future" envelopes
    bytes32 public constant ADMIN_ROLE = keccak256("FX_ROUTER_ADMIN");

    // External deps (immutable)
    IPermit2  public immutable PERMIT2;          // 0x000000000022D473030F116dDEE9F6B43aC78BA3
    IFxSwapHook public immutable HOOK;           // FxSwapHook deployed instance
    IPoolManager public immutable POOL_MANAGER;  // Uniswap v4 PoolManager
    PoolKey public POOL_KEY;                     // Locked at deploy; one pair per router instance

    // Mutable governance
    address public treasury;
    uint48  public maxFeeBps;        // <= MAX_FEE_BPS_HARD_CAP
    bool    public paused;

    // Replay + pair allowlist
    mapping(address => mapping(uint256 => bool)) public isIntentUuidUsed;
    mapping(address => mapping(address => bool)) public isPairAllowed;
}
```

### 3.5 `executeIntent` — semantics, step by step

Order matters. Fail fast.

1. **`whenNotPaused`** — revert `PausedRouter` if paused.
2. **`nonReentrant`** via transient lock.
3. **Validate envelope:**
   - `intent.taker != address(0)` else `TakerZero`.
   - `intent.recipient != address(0)` else `RecipientZero`.
   - `block.timestamp <= intent.deadline` else `IntentExpired`.
   - `intent.deadline <= block.timestamp + MAX_DEADLINE_FUTURE` (stale-far-future guard).
   - `intent.tenor == TENOR_INSTANT` else `UnsupportedTenor`.
   - `isPairAllowed[intent.sellToken][intent.buyToken]` else `UnsupportedPair`.
   - `intent.feeBps <= maxFeeBps` else `FeeBpsTooHigh`.
4. **Replay protection:**
   - `!isIntentUuidUsed[intent.taker][intent.uuid]` else `UuidAlreadyUsed`.
   - Mark used **before** external calls (CEI).
5. **Signature verification:**
   - `bytes32 digest = _hashTypedDataV4(FxRouterLib.hashIntent(intent));`
   - `require(SignatureChecker.isValidSignatureNowCalldata(intent.taker, digest, intentSig), InvalidSignature);`
6. **Permit2 coherence check:**
   - `permit.permitted.token == intent.sellToken`
   - `permit.permitted.amount == intent.sellAmount`
   - else `SellAmountMismatch`. Witness pattern OPTIONAL — see §3.8.
7. **Pull funds:**
   - `PERMIT2.permitTransferFrom(permit, IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: intent.sellAmount}), intent.taker, permitSig);`
8. **Fee skim:**
   - `protocolFee = (intent.sellAmount * intent.feeBps) / BPS_DENOMINATOR;`
   - `sellAfterFee = intent.sellAmount - protocolFee;`
9. **Swap:**
   - Approve `POOL_MANAGER` for `sellAfterFee` of `sellToken` (use `forceApprove`).
   - Call `IPoolManager.swap` (v4 unlock pattern — use the existing helper in `FxSwapHook` or a thin wrapper). Direction inferred from `POOL_KEY` token0/token1 ordering vs `sellToken`.
   - Capture actual `buyAmount` from BalanceDelta.
10. **Slippage check:**
    - `buyAmount >= intent.minBuyAmount` else `InsufficientOutput`.
11. **Deliver:**
    - `IERC20(intent.buyToken).safeTransfer(intent.recipient, buyAmount);`
    - `IERC20(intent.sellToken).safeTransfer(treasury, protocolFee);` (skip if `protocolFee == 0`).
12. **Emit:**
    - `IntentExecuted(intentHash, taker, recipient, sellToken, sellAmount, buyToken, buyAmount, protocolFee, quoteId);`
    - `ProtocolFeeCollected(sellToken, protocolFee);` if non-zero.

### 3.6 Permit2 integration details

- Use `IPermit2.PermitTransferFrom` (single-use signed transfer, NOT `AllowanceTransfer`).
- Reference: `lib/permit2/src/interfaces/ISignatureTransfer.sol`. Add `permit2` to `foundry.toml` `remappings.txt` and `lib/`.
- Canonical address `0x000000000022D473030F116dDEE9F6B43aC78BA3` is the same on Arc, Base Sepolia, mainnet — pass via constructor for testability but assert in deploy script that the address matches the canonical one (or that bytecode hash matches expected — for tenderly vnet primed state).
- Client UX: one `IERC20(sellToken).approve(PERMIT2, type(uint256).max)` per token, then per-trade EIP-712 sig. Standard StableFX pattern.

**Witness option (optional, recommend YES):** Use Permit2 `permitWitnessTransferFrom` so the Permit2 sig itself commits to the FxIntent hash. This collapses two sigs into one for clients that support it (most modern SDKs do). Add as `executeIntentWithWitness` overload OR replace primary entry. **Recommend:** primary entry uses witness pattern, keep separate `intentSig` for EIP-1271/7702 wallets that can't do Permit2-witness yet. Document the choice in NatSpec.

### 3.7 Signature checker — multi-wallet support

```solidity
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

// In _verifyIntent:
if (!SignatureChecker.isValidSignatureNowCalldata(intent.taker, digest, intentSig)) {
    revert InvalidSignature();
}
```

This single call handles:
- ECDSA EOAs
- EIP-1271 smart-contract wallets (Safe, Argent, ZeroDev, Biconomy)
- EIP-7702 delegated EOAs (signer is an EOA whose code is an authorized 1271-compatible delegate)

Critical for Hinkal-wrapped flow: the per-deposit fresh SCA signs, and our router validates it without needing wallet-type detection logic.

### 3.8 Admin + governance

- `AccessControl`. `DEFAULT_ADMIN_ROLE` is the Compound Timelock (same one used elsewhere in fx-Telaraña). Deploy script transfers admin to timelock and asserts post-condition.
- `ADMIN_ROLE` (the *operational* admin, behind timelock) gates `setTreasury`, `setMaxFeeBps`, `setPairAllowed`, `pause`.
- `pause(true)` is callable by `ADMIN_ROLE` with **no timelock** (emergency). `pause(false)` requires timelock. (Same pattern as Sera; document in NatSpec.)
- `maxFeeBps` is bounded by `MAX_FEE_BPS_HARD_CAP = 1e12` (1%) in the constructor — admin cannot exceed this even via timelock.

### 3.9 Reentrancy

- `ReentrancyGuardTransient` on `executeIntent`.
- Permit2's `permitTransferFrom` calls into `sellToken.transferFrom`. If `sellToken` is a malicious ERC-777-style token, the transient lock catches reentrancy. Whitelist tokens at deploy (USDC, EURC) so this is belt-and-suspenders.

### 3.10 What `FxRouter` MUST NOT do

- ❌ Call `IFxOracle` directly. Pricing is the hook's job; router just delivers a signed intent into the hook.
- ❌ Derive `recipient` from `msg.sender`. Always use `intent.recipient` (the Hinkal discipline).
- ❌ Hold ERC-20 balances across blocks. All sellToken pulled MUST be either swapped or refunded within the same tx.
- ❌ Implement its own oracle deviation gate. The hook already does this on swap.
- ❌ Use storage for transient route state. Use memory or transient storage (EIP-1153) only.

---

## 4. Off-chain — Pasillo Quote API (Phase 3a)

### 4.1 Architecture

Pasillo is the routing brain. It exposes ONE quote endpoint that internally fans out to:

1. **fx-Telaraña AMM read path** — read `FxSwapHook.quoteExactInput` (need to expose; see §5.2) + oracle deviation + reserves to compute an executable quote with slippage budget.
2. **Circle StableFX RFQ** — `POST /v1/exchange/quotes` per StableFX technical guide (`pasted_text_2026-05-14_17-33-22.txt`). Requires `LIVE` or `TEST` API key.
3. (Future) Other CLOB rails (Sera-licensed deployment, Hashflow, etc.)

Pasillo decides the winner by:
- Net buy-amount (after both protocols' fees) — primary.
- Tenor compatibility — fx-Telaraña only supports instant.
- KYB gate — if client is unvetted, force `route=fx-telarana`.
- Pair availability — if either rail doesn't support the pair, route to the other.

### 4.2 HTTP API contract

```
POST /v1/quote
Authorization: Bearer <pasillo_api_key>
Content-Type: application/json

Request:
{
  "from": { "currency": "USDC", "amount": "1000000000" },  // 1000 USDC (6 dec)
  "to":   { "currency": "EURC" },
  "tenor": "instant",
  "recipient": "0xAbc...",     // hub-side beneficiary, OR client EOA in non-confidential
  "kyc_token": "..." | null,    // Hinkal access token if confidential
  "client_idempotency_key": "uuid-v4"
}

Response (200):
{
  "quote_id": "fxt_q_abc123...",
  "route": "fx-telarana" | "stablefx",
  "expiry": "2026-05-14T17:45:00Z",      // 10-minute window (StableFX-compatible)
  "from": { "currency": "USDC", "amount": "1000000000" },
  "to":   { "currency": "EURC", "amount": "925400000" },
  "rate": "0.9254",
  "fees": {
    "protocol_bps": "5000000000",        // 5 bps in 1e14 denom = 0.05%
    "protocol_amount": "500000",         // in `from` currency
    "expected_slippage_bps": "2000000000"
  },
  "envelope": {
    // ONE of the following, depending on `route`:
    "fx-telarana": {
      "domain": { "name": "fx-Telarana-FxRouter", "version": "1", "chainId": 5042002, "verifyingContract": "0x..." },
      "types":  { "FxIntent": [ ... ] },
      "primaryType": "FxIntent",
      "message": {
        "taker": "0x...",
        "recipient": "0x...",
        "sellToken": "0x3600...",       // USDC on Arc
        "buyToken":  "0x89B5...",       // EURC on Arc
        "sellAmount": "1000000000",
        "minBuyAmount": "923548000",    // includes slippage budget
        "deadline": 1715706300,
        "feeBps": "5000000000",
        "tenor": 0,
        "quoteId": "0x...",             // keccak256 of off-chain quote_id
        "uuid": "1234567890..."
      },
      "router_address": "0x...",
      "permit2_address": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
      "permit2_template": {             // client fills nonce, deadline, signs
        "permitted": { "token": "0x3600...", "amount": "1000000000" },
        "nonce": "auto",
        "deadline": 1715706300
      }
    },
    "stablefx": {
      "stablefx_quote_id": "...",       // pass-through from Circle
      "submit_endpoint": "https://api.circle.com/v1/exchange/trades",
      "taker_details_eip712": { ... },
      "fx_escrow_address": "0x867650F5eAe8df91445971f14d89fd84F0C9a9f8"
    }
  }
}
```

### 4.3 Execution endpoint

```
POST /v1/execute
Authorization: Bearer <pasillo_api_key>

Request (fx-telarana route):
{
  "quote_id": "fxt_q_abc123...",
  "intent_signature": "0x...",      // FxIntent EIP-712 sig
  "permit2_signature": "0x...",     // Permit2 sig
  "permit2_nonce": "...",
  "permit2_deadline": "..."
}

Request (stablefx route):
{
  "quote_id": "fxt_q_abc123...",
  "taker_signature": "0x...",
  ... (forwarded to Circle execution engine)
}

Response:
{
  "tx_hash": "0x...",                 // fx-telarana: on-chain hash; stablefx: from Circle
  "buy_amount_delivered": "...",
  "protocol_fee_collected": "...",
  "trade_id": "..."                   // stablefx returns FxEscrow contract trade ID
}
```

### 4.4 Routing decision tree (Pasillo internal)

```
1. Tenor != instant?
   → route = stablefx (only path)

2. Either side unsupported by AMM (pair allowlist)?
   → route = stablefx

3. Client lacks StableFX KYB?
   → route = fx-telarana (or reject if pair unsupported there)

4. AMM quote vs StableFX RFQ:
   buyAmount_fxt = AMM exactInput - hook fees
   buyAmount_sfx = StableFX RFQ response
   route = argmax(buyAmount_fxt, buyAmount_sfx)

5. Tie-break: prefer fx-telarana (latency, censorship-resistance, no Circle dependency)
```

### 4.5 What Pasillo needs to provision

- **fx-Telaraña RPC** + read-only `FxSwapHook` quoter. Wrap viem client.
- **Circle StableFX API key.** Per `pasted_text_2026-05-14_17-32-57.txt`, request via Circle sales rep.
- **KYB registry.** Maps Pasillo `client_id` → (is StableFX-vetted? Y/N), (Hinkal-eligible? Y/N), (Talos maker? Y/N).
- **Quote cache + idempotency.** `client_idempotency_key` → quote response; replay returns same envelope until expiry.
- **Telemetry.** Win-rate vs StableFX, slippage realized vs quoted, per-route latency.

### 4.6 Suggested Pasillo repo layout

```
pasillo/
  apps/api/                      # the HTTP server
    src/quoter/fxTelarana.ts     # AMM read-path quoter
    src/quoter/stablefx.ts       # Circle RFQ client
    src/router/decide.ts         # routing tree (§4.4)
    src/envelope/fxIntent.ts     # EIP-712 builder + abigen types
    src/envelope/stablefx.ts     # StableFX TakerDetails builder
    src/execute/fxTelarana.ts    # tx submission to Arc RPC
    src/execute/stablefx.ts      # POST to Circle execution engine
  packages/sdk-ts/               # public Pasillo TS SDK for institutional clients
```

---

## 5. Changes needed in adjacent contracts

### 5.1 `FxSwapHook.sol` — add `quoteExactInput` view

Pasillo needs to read an executable AMM quote off-chain without simulating a full swap. Add:

```solidity
function quoteExactInput(address sellToken, uint256 sellAmount)
    external view returns (uint256 expectedBuyAmount, uint256 oraclePrice, uint256 effectiveReservesIn, uint256 effectiveReservesOut);
```

Reuse the existing PMM math path; do not allocate state. If math currently lives in a helper internal lib, expose a thin view wrapper.

### 5.2 Deploy + addresses

- Add `FxRouter` deployment to `script/Deploy.s.sol` and `script/DeployTestnet.s.sol` (Tenderly + Base Sepolia variants).
- Add address to `deployments/base-sepolia.json`, `deployments/tenderly-base-sepolia.json`, future `deployments/arc-testnet.json`.
- Add SDK exports in `packages/sdk/src/addresses/index.ts` under `ChainId.BaseSepolia` and friends.
- Register with Circle SCP via `bun run sdk:circle:register` after deploy.

### 5.3 SDK additions (`packages/sdk/`)

- `packages/sdk/src/fxRouter/` — typed wrappers around `executeIntent`, `hashIntent`, EIP-712 builders, Permit2 builders.
- `packages/sdk/src/fxRouter/__tests__/` — unit tests for envelope construction matching contract abi.

---

## 6. Test plan

Acceptance: **all** of the following pass on `bun run contracts:test` and `bun run contracts:test:fork`.

### 6.1 Unit (`FxRouter.t.sol`)

- ✅ Happy path: EOA signs, Permit2 pull, AMM swap, buyToken delivered to recipient, fee to treasury.
- ✅ `recipient != taker` — buyToken goes to recipient (not taker).
- ✅ `recipient == address(0)` reverts `RecipientZero`.
- ✅ `taker == address(0)` reverts `TakerZero`.
- ✅ Expired intent reverts `IntentExpired`.
- ✅ Stale-far-future deadline (> `block.timestamp + MAX_DEADLINE_FUTURE`) reverts.
- ✅ Replay (same uuid twice) reverts `UuidAlreadyUsed`.
- ✅ Wrong signature reverts `InvalidSignature`.
- ✅ Wrong recovered signer reverts `InvalidSignature`.
- ✅ `permit.amount != intent.sellAmount` reverts `SellAmountMismatch`.
- ✅ `permit.token != intent.sellToken` reverts `SellAmountMismatch` (or distinct error).
- ✅ Unsupported pair reverts `UnsupportedPair`.
- ✅ `feeBps > maxFeeBps` reverts `FeeBpsTooHigh`.
- ✅ AMM out < `minBuyAmount` reverts `InsufficientOutput`.
- ✅ `pause(true)` blocks `executeIntent`, `pause(false)` re-enables.
- ✅ `tenor != 0` reverts `UnsupportedTenor`.
- ✅ `feeBps == 0` path: no transfer to treasury, no `ProtocolFeeCollected` event.
- ✅ `IntentExecuted` event has correct `intentHash`, `buyAmount`, `protocolFee`, `quoteId`.

### 6.2 EIP-1271 / 7702 (`FxRouter.eip1271.t.sol`)

- ✅ Safe-style smart wallet (mock `IERC1271`) signs, router validates via SignatureChecker.
- ✅ Smart wallet that returns wrong magic value → `InvalidSignature`.
- ✅ EIP-7702-delegated EOA signs (simulate via mock delegate code).
- ✅ Smart wallet recipient ≠ signer wallet (institutional sub-account pattern).

### 6.3 Permit2 (`FxRouter.permit2.t.sol`)

- ✅ Fresh Permit2 nonce works.
- ✅ Replayed Permit2 nonce reverts (Permit2's own protection — sanity).
- ✅ Permit2 deadline before intent deadline reverts.
- ✅ Witness pattern (if implemented): wrong witness reverts.

### 6.4 Fuzz (`FxRouter.fuzz.t.sol`)

- ✅ Arbitrary `sellAmount` in `[1, type(uint128).max]` — no underflow, no overflow, fee math monotonic.
- ✅ Arbitrary `feeBps` in `[0, maxFeeBps]` — fee + delivered + treasury always balances.
- ✅ Random `recipient` addresses (excluding zero and contract) all receive correctly.

### 6.5 Fork (`FxRouter.fork.t.sol`, run with `bun run contracts:test:fork`)

- ✅ Against real Permit2 on Base Sepolia: full signed flow, USDC→EURC swap via real `FxSwapHook` deployment.
- ✅ Against real Permit2 on Tenderly vnet: same.

### 6.6 SDK (`packages/sdk/src/fxRouter/__tests__/`)

- ✅ EIP-712 envelope from SDK hashes identically to `FxRouterLib.hashIntent` in Solidity (cross-check via abigen).
- ✅ Permit2 envelope builds correctly with `PermitTransferFrom` schema.
- ✅ End-to-end Pasillo quote response → client signs → tx broadcast (mocked RPC).

---

## 7. Security review checklist (gateman pass before merge)

Before opening the PR, agent confirms:

- [ ] No `msg.sender`-derived recipient anywhere in the call path.
- [ ] CEI ordering: `isIntentUuidUsed` flipped to true BEFORE Permit2/swap external calls.
- [ ] `forceApprove` (not `approve`) on `PoolManager` — handles USDT-style approve-race tokens. (USDC/EURC don't need this, but future stablecoins might.)
- [ ] No `unchecked` blocks unless explicitly proven safe (document the proof).
- [ ] All admin functions gated by `AccessControl` role check + timelock.
- [ ] `pause()` true-path requires no timelock; false-path requires timelock.
- [ ] Fee math: `(sellAmount * feeBps) / BPS_DENOMINATOR` never overflows for `sellAmount <= type(uint128).max` and `feeBps <= MAX_FEE_BPS_HARD_CAP` (proof: `2^128 * 1e12 < 2^256`).
- [ ] `MAX_DEADLINE_FUTURE` enforced (prevent stale-far-future signed envelopes).
- [ ] `executeIntent` is `external`, not `public` (calldata only, gas optimal, and prevents internal misuse).
- [ ] `IFxOracle` not called from router (oracle reads happen inside hook only).
- [ ] No storage writes after external calls except the final event emit.
- [ ] Run `forge inspect FxRouter storageLayout` — confirm slot layout sane for future upgrade-via-replace (we're not using proxies, but document anyway).
- [ ] Slither + Aderyn passes with no medium+ findings.

---

## 8. Open questions for the implementing agent to surface

1. **Permit2 witness or separate-sig pattern as primary entry?** Recommend witness as primary, separate-sig as fallback for 1271 wallets. Confirm with Pasillo's wallet integration plan before implementing.
2. **Should `FxRouter` be one-pair-per-instance (current spec) or multi-pair (one router, registry of allowed pairs)?** Multi-pair is more ops-friendly but requires per-tx `PoolKey` lookup. Recommend **multi-pair via `isPairAllowed` mapping + per-pair `PoolKey` registry**. Update §3.4 storage if going this route.
3. **Treasury per-pair or global?** Global simpler. Per-pair lets us split fees to per-pair LP incentive pools later. Recommend global for v1.
4. **`MAX_FEE_BPS_HARD_CAP`** — `1e12` = 1%. Is this right for the FX use case? Institutional FX typically ≤ 10 bps total. Recommend lowering to `5e11` (0.5%) and revisiting if real flow data justifies.
5. **StableFX integration: should Pasillo proxy or just hand the client a signed envelope to submit directly?** Proxy = better telemetry, single point of monitoring. Direct = lower latency, lower Pasillo trust surface. Recommend **proxy by default with direct-submit as opt-in**.

---

## 9. Sequencing

1. **Week 1:** `FxRouterLib.sol` + `IFxRouter.sol` + EIP-712 hashing + Permit2 plumbing. Unit tests up to §6.1.
2. **Week 2:** Hook integration (`FxSwapHook.quoteExactInput` view + swap path call). EIP-1271/7702 tests. Fuzz suite.
3. **Week 3:** SDK wrappers (`packages/sdk/src/fxRouter/`). Pasillo quote API skeleton (Phase 3a, separate repo).
4. **Week 4:** Tenderly vnet deploy + Base Sepolia deploy + Circle SCP registration. Fork tests green.
5. **Week 5:** Slither/Aderyn pass. Internal review. Open PR.
6. **Pre-Arc-mainnet:** External audit (CertiK or Spearbit). Same auditor as core if budget allows.

---

## 10. Done = ?

This phase is done when:

1. `bun run contracts:test` → all green (existing 42/42 + new FxRouter suite).
2. `bun run contracts:test:fork` → all green.
3. `bun run sdk:test` → all green (existing 20/20 + new fxRouter envelope tests).
4. `FxRouter` deployed to Tenderly vnet + Base Sepolia, addresses in `deployments/*.json` + SDK addresses.
5. Circle SCP registered (idempotent `bun run sdk:circle:register`).
6. Pasillo `POST /v1/quote` returns a valid signable envelope for USDC↔EURC on Base Sepolia (Phase 3a deliverable).
7. End-to-end demo: institutional client signs once in their Safe, Pasillo routes to fx-Telaraña, swap executes, EURC lands in client-specified recipient. Same flow but Pasillo routes to StableFX → identical client-facing UX.
8. Gateman checklist (§7) complete.

— end of spec —
