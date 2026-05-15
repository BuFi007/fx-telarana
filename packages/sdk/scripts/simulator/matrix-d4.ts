// SPDX-License-Identifier: AGPL-3.0-only
/**
 * Drop 4 matrix additions:
 *   E — Pyth-fresh oracle sims (bundle a Hermes payload + getMidWithUpdatePyth)
 *   C+ — primed Morpho borrow (supply liquidity before the borrow tries)
 *   C++ — sweep happy path (storage-override `_deposits[nonce]` + advance time)
 */
import {
  encodeFunctionData,
  keccak256,
  encodeAbiParameters,
  parseAbi,
  pad,
  toHex,
  concat,
  type Address,
  type Hex,
} from "viem";
import { balanceSlot, valueHex as hex32, type SimulateRequest } from "./client.js";
import { PERSONAS, personaState } from "./personas.js";
import type { TestCase } from "./matrix.js";

type HubManifest = {
  network: string;
  chainId: number;
  contracts: {
    FxOracle: Address;
    FxMarketRegistry: Address;
    FxReceiptUSDC: Address;
    FxReceiptEURC: Address;
    FxLiquidator: Address;
    FxHubMessageReceiver: Address;
    FxSwapHook: Address;
    MorphoOracleAdapterM1: Address;
    MorphoOracleAdapterM2: Address;
  };
  external: { USDC: Address; EURC: Address; MorphoBlue: Address; Pyth: Address };
};

const PYTH_USDC_USD = "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a";
const PYTH_EURC_USD = "0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c";

/** Fetch a fresh Pyth Hermes payload covering USDC/USD + EURC/USD. */
export async function fetchPythUpdate(): Promise<Hex[]> {
  const url = `https://hermes.pyth.network/api/latest_vaas?ids[]=${PYTH_USDC_USD}&ids[]=${PYTH_EURC_USD}`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`Hermes ${r.status}: ${await r.text()}`);
  const vaas = (await r.json()) as string[]; // base64 strings
  return vaas.map((b64) => `0x${Buffer.from(b64, "base64").toString("hex")}` as Hex);
}

const ORACLE_ABI = parseAbi([
  "function getMidWithUpdatePyth(address base, address quote, bytes[] pythUpdate) external payable returns (uint256, uint256)",
]);

/// Category E — Pyth-fresh oracle reads. With a Hermes payload bundled in
/// the same tx the OracleStale revert from Drop 3 flips to a clean pass.
export function categoryE(hub: HubManifest, pythUpdate: Hex[]): TestCase[] {
  const out: TestCase[] = [];
  const whale = PERSONAS.whale;

  // E1 — getMidWithUpdatePyth(USDC, EURC). Pay 100 wei to cover Pyth fee.
  out.push({
    id: "E.pyth-fresh.usdc-eurc",
    description: "getMidWithUpdatePyth(USDC, EURC) with fresh Hermes payload — expect pass",
    request: {
      network_id: String(hub.chainId),
      from: whale.address,
      to: hub.contracts.FxOracle,
      input: encodeFunctionData({
        abi: ORACLE_ABI,
        functionName: "getMidWithUpdatePyth",
        args: [hub.external.USDC, hub.external.EURC, pythUpdate],
      }),
      value: "1000000000000000", // 0.001 ETH — over-pay; excess refunded
      state_objects: {
        // Native ETH for the caller (no token overrides needed).
        [whale.address]: { balance: "0x8AC7230489E80000" }, // 10 ETH
      },
    },
    expect: { kind: "pass" },
  });

  // E2 — reverse direction.
  out.push({
    id: "E.pyth-fresh.eurc-usdc",
    description: "getMidWithUpdatePyth(EURC, USDC) with fresh Hermes payload — expect pass",
    request: {
      network_id: String(hub.chainId),
      from: whale.address,
      to: hub.contracts.FxOracle,
      input: encodeFunctionData({
        abi: ORACLE_ABI,
        functionName: "getMidWithUpdatePyth",
        args: [hub.external.EURC, hub.external.USDC, pythUpdate],
      }),
      value: "1000000000000000",
      state_objects: {
        [whale.address]: { balance: "0x8AC7230489E80000" },
      },
    },
    expect: { kind: "pass" },
  });

  return out;
}

const ADAPTIVE_IRM: Address = "0x46415998764C29aB2a25CbeA6254146D50D22687";
const LLTV: bigint = 860000000000000000n;

function m2Params(hub: HubManifest) {
  return {
    loanToken: hub.external.USDC,
    collateralToken: hub.external.EURC,
    oracle: hub.contracts.MorphoOracleAdapterM2,
    irm: ADAPTIVE_IRM,
    lltv: LLTV,
  };
}

const MORPHO_ABI = parseAbi([
  "function supply((address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external returns (uint256, uint256)",
  "function supplyCollateral((address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams, uint256 assets, address onBehalf, bytes data) external",
  "function borrow((address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external returns (uint256, uint256)",
]);

/// Category C-primed — borrow with prior supply liquidity. The two failing
/// Drop 3 cases were `supplyCollateral + borrow` against an empty market;
/// Morpho can't issue debt with no supply. This bundle:
///   1. Whale supplies 5000 USDC into M2 (loan side liquidity)
///   2. Whale supplies 1000 EURC as collateral
///   3. Whale borrows 500 USDC against EURC
export function categoryCPrimedBorrow(hub: HubManifest, pythUpdate: Hex[]): TestCase[] {
  const out: TestCase[] = [];
  const whale = PERSONAS.whale;

  // Pre-load whale with USDC + EURC + ETH for gas + Pyth fee.
  // Also: pre-fund the oracle adapter with a refreshed Pyth feed so
  // Morpho's price check inside borrow doesn't revert on staleness.
  const state = personaState(whale, hub.external.USDC, hub.external.MorphoBlue, hub.external.EURC);
  state[whale.address] = { balance: "0x8AC7230489E80000" };

  const supplyLiquidity = encodeFunctionData({
    abi: MORPHO_ABI,
    functionName: "supply",
    args: [m2Params(hub), 5_000_000_000n, 0n, whale.address, "0x"],
  });
  const supplyCollat = encodeFunctionData({
    abi: MORPHO_ABI,
    functionName: "supplyCollateral",
    args: [m2Params(hub), 1_000_000_000n, whale.address, "0x"],
  });

  // Refresh the oracle first by calling FxOracle.getMidWithUpdatePyth
  // (MorphoOracleAdapter reads from FxOracle.getMid). Pyth has to be fresh.
  const refresh = encodeFunctionData({
    abi: ORACLE_ABI,
    functionName: "getMidWithUpdatePyth",
    args: [hub.external.USDC, hub.external.EURC, pythUpdate],
  });

  const borrowCall = encodeFunctionData({
    abi: MORPHO_ABI,
    functionName: "borrow",
    args: [m2Params(hub), 500_000_000n, 0n, whale.address, whale.address],
  });

  out.push({
    id: "C.borrow.primed",
    description: "supply 5k USDC + 1k EURC collateral, refresh oracle, borrow 500 USDC",
    request: {
      network_id: String(hub.chainId),
      from: whale.address,
      to: hub.external.MorphoBlue,
      input: borrowCall,
    },
    expect: { kind: "pass" },
    bundle: [
      {
        network_id: String(hub.chainId),
        from: whale.address,
        to: hub.external.MorphoBlue,
        input: supplyLiquidity,
        state_objects: state,
      },
      {
        network_id: String(hub.chainId),
        from: whale.address,
        to: hub.external.MorphoBlue,
        input: supplyCollat,
      },
      {
        network_id: String(hub.chainId),
        from: whale.address,
        to: hub.contracts.FxOracle,
        input: refresh,
        value: "1000000000000000",
      },
      {
        network_id: String(hub.chainId),
        from: whale.address,
        to: hub.external.MorphoBlue,
        input: borrowCall,
      },
    ],
  } as TestCase);
  return out;
}

const RECEIVER_ABI = parseAbi([
  "function sweepStrandedDeposit(bytes32 messageNonce) external",
]);

/**
 * Compute the storage slot for `_deposits[nonce]` inside FxHubMessageReceiver.
 *
 * Layout (verified via `forge inspect ... storage-layout`):
 *   slot 0: mapping(bytes32 => StrandedDeposit) _deposits
 * ReentrancyGuard in our OpenZeppelin version uses transient storage
 * (EIP-1153), so it consumes no permanent slot.
 *
 * StrandedDeposit packs as:
 *   slot 0: beneficiary (20B) | amount uint96 (12B)
 *   slot 1: strandedAt uint64 (8B) | state uint8 (1B) | padding (23B)
 */
function depositSlot(nonce: Hex): { slotA: Hex; slotB: Hex; pack: (b: Address, a: bigint, t: bigint, s: number) => { a: Hex; b: Hex } } {
  const base = keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [nonce, 0n]),
  );
  const slotA = base;
  // next slot: BigInt(base) + 1n, hex-padded
  const slotB = pad(toHex(BigInt(base) + 1n), { size: 32 });
  return {
    slotA,
    slotB,
    pack: (beneficiary, amount, strandedAt, state) => {
      // slot A: address (20B low) | amount uint96 (12B high)
      const a = pad(toHex((amount << 160n) | BigInt(beneficiary)), { size: 32 });
      // slot B: strandedAt (8B low) | state (1B at byte 8)
      const b = pad(toHex((BigInt(state) << 64n) | strandedAt), { size: 32 });
      return { a, b };
    },
  };
}

/// Category F-hook (admin/auth surface): non-owner calls to owner-only
/// setters on FxSwapHook all revert. These tests assert the auth gates
/// are wired correctly, and exercise the contract beyond the read-only
/// accessors Drop 3 covered.
const HOOK_ADMIN_ABI = parseAbi([
  "function setSpreadBps(uint16) external",
  "function setHotReservePct(uint16) external",
  "function setKBps(uint16) external",
]);

export function categoryFAdminGuards(hub: HubManifest): TestCase[] {
  const out: TestCase[] = [];
  const stranger = PERSONAS.mid.address;

  for (const [fn, arg] of [
    ["setSpreadBps", 5n],
    ["setHotReservePct", 1500n],
    ["setKBps", 10n],
  ] as Array<["setSpreadBps" | "setHotReservePct" | "setKBps", bigint]>) {
    out.push({
      id: `Auth.hook.${fn}.non-owner`,
      description: `FxSwapHook.${fn} from non-owner — expect revert`,
      request: {
        network_id: String(hub.chainId),
        from: stranger,
        to: hub.contracts.FxSwapHook,
        input: encodeFunctionData({
          abi: HOOK_ADMIN_ABI,
          functionName: fn,
          args: [Number(arg)],
        }),
      },
      expect: { kind: "revert" },
    });
  }
  return out;
}

/// Category C-sweep — fake a stranded deposit via storage overrides, then
/// (1) sweep before grace → revert, (2) sweep with ancient strandedAt so
/// current block.timestamp is naturally past grace → pass.
export function categoryCSweep(hub: HubManifest): TestCase[] {
  const out: TestCase[] = [];
  const beneficiary = PERSONAS.mid.address;
  const amount = 1_000_000_000n; // 1000 USDC
  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const STATE_STRANDED = 2;

  // C.sweep.before-grace: strandedAt = now - 60s. Current block timestamp
  // is roughly `nowSec`. Grace = 24h. So grace-end is ~24h in the future
  // → call reverts GraceUnexpired.
  {
    const strandedAt = nowSec - 60n;
    const { slotA, slotB, pack } = depositSlot(
      "0xfeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" as Hex,
    );
    const packed = pack(beneficiary, amount, strandedAt, STATE_STRANDED);
    out.push({
      id: "C.sweep.before-grace",
      description: "sweep stranded deposit before 24h grace — expect GraceUnexpired revert",
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxHubMessageReceiver,
        input: encodeFunctionData({
          abi: RECEIVER_ABI,
          functionName: "sweepStrandedDeposit",
          args: ["0xfeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" as Hex],
        }),
        state_objects: {
          [hub.contracts.FxHubMessageReceiver]: { storage: { [slotA]: packed.a, [slotB]: packed.b } },
          [hub.external.USDC]: {
            storage: { [balanceSlot(hub.contracts.FxHubMessageReceiver, 9)]: hex32(amount) },
          },
        },
      },
      expect: { kind: "revert" },
    });
  }

  // C.sweep.after-grace: instead of trying to advance the chain clock,
  // backdate the deposit. Setting strandedAt to 2024-01-01 (a year+ ago)
  // means current block.timestamp - strandedAt is already >> 24h grace.
  // No time-override needed — current state of the chain naturally
  // satisfies `block.timestamp >= strandedAt + GRACE`.
  {
    const ancientStrandedAt = 1704067200n; // 2024-01-01 00:00:00 UTC
    const { slotA, slotB, pack } = depositSlot(
      "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex,
    );
    const packed = pack(beneficiary, amount, ancientStrandedAt, STATE_STRANDED);
    out.push({
      id: "C.sweep.after-grace",
      description: "sweep with strandedAt backdated to 2024 — current block is naturally past grace → expect pass",
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxHubMessageReceiver,
        input: encodeFunctionData({
          abi: RECEIVER_ABI,
          functionName: "sweepStrandedDeposit",
          args: ["0x1111111111111111111111111111111111111111111111111111111111111111" as Hex],
        }),
        state_objects: {
          [hub.contracts.FxHubMessageReceiver]: { storage: { [slotA]: packed.a, [slotB]: packed.b } },
          [hub.external.USDC]: {
            storage: { [balanceSlot(hub.contracts.FxHubMessageReceiver, 9)]: hex32(amount) },
          },
        },
      },
      expect: { kind: "pass" },
    });
  }

  return out;
}
