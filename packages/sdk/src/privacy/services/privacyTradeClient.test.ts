// SPDX-License-Identifier: Apache-2.0
//
// PrivacyTradeClient — unit tests for the integrator-facing surface.
// Chain interaction (shield/relay/buildStateMerkleProof) is exercised
// live via packages/privacy-prover/scripts/b5-*.ts and verified on Arc
// Testnet; this file covers the wiring that doesn't need a chain:
// config lookup, error paths, and serialize/deserialize.

import { describe, expect, test } from "bun:test";

import {
  PRIVACY_CHAIN_CONFIGS,
  PrivacyTradeClient,
  type ShieldedNote,
} from "./privacyTradeClient.js";

const ARC_CHAIN_ID = 5042002;
const FUJI_CHAIN_ID = 43113;

describe("PRIVACY_CHAIN_CONFIGS", () => {
  test("Arc Testnet entries match live deploy manifest", () => {
    const cfg = PRIVACY_CHAIN_CONFIGS[ARC_CHAIN_ID]!;
    expect(cfg.entrypoint).toBe("0xD11cDdd1f04e850d3810a71608A49907c80f2736");
    expect(cfg.pools.USDC?.pool).toBe("0xC11C216C9C7A36848b1d4276d223160C8b51988f");
    expect(cfg.pools.USDC?.asset).toBe("0x3600000000000000000000000000000000000000");
    expect(cfg.pools.EURC?.pool).toBe("0x7B4582CDE65c8cC00fE24B16dBA60472242d234c");
    expect(cfg.pools.EURC?.asset).toBe("0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a");
    // Scopes — verified live via cast call <pool> SCOPE().
    expect(cfg.pools.USDC?.scope).toBe(
      13628782019290114344365157513531312776376936678300719745279061801973571818236n,
    );
    expect(cfg.pools.EURC?.scope).toBe(
      10011405322814872543637273959896594613590433782049698944750253296575874394014n,
    );
  });

  test("Fuji entry has the USDC pool only (no cross-ccy yet)", () => {
    const cfg = PRIVACY_CHAIN_CONFIGS[FUJI_CHAIN_ID]!;
    expect(cfg.entrypoint).toBe("0x6d5e3D5bE0Be2B29D48EDa2FA35Fa8d787D3C953");
    expect(Object.keys(cfg.pools)).toEqual(["USDC"]);
    // Fuji's public RPC caps eth_getLogs at 2048 — must be under.
    expect(cfg.maxRangePerCall).toBeLessThanOrEqual(2048n);
  });
});

describe("PrivacyTradeClient.forChain", () => {
  const stubClient = {} as never;
  const stubProver = {
    proveWithdrawal: async () => ({ proof: {} as never, publicSignals: [] }),
  };

  test("unknown chainId throws with the known list", () => {
    expect(() =>
      PrivacyTradeClient.forChain({
        chainId: 999_999_999,
        publicClient: stubClient,
        walletClient: stubClient,
        prover: stubProver,
      }),
    ).toThrow(/no config for chainId/i);
  });

  test("Arc chainId returns a wired client whose config matches the live deploy", () => {
    const c = PrivacyTradeClient.forChain({
      chainId: ARC_CHAIN_ID,
      publicClient: stubClient,
      walletClient: stubClient,
      prover: stubProver,
    });
    expect(c.config.chainId).toBe(ARC_CHAIN_ID);
    expect(c.config.pools.USDC).toBeDefined();
    expect(c.config.pools.EURC).toBeDefined();
  });

  test("pool() throws on unknown symbol with available list", () => {
    const c = PrivacyTradeClient.forChain({
      chainId: ARC_CHAIN_ID,
      publicClient: stubClient,
      walletClient: stubClient,
      prover: stubProver,
    });
    expect(() => c.pool("BOGUS")).toThrow(/no pool for BOGUS/);
    expect(() => c.pool("BOGUS")).toThrow(/USDC, EURC/);
  });

  test("pool() returns the live entry for a known symbol", () => {
    const c = PrivacyTradeClient.forChain({
      chainId: ARC_CHAIN_ID,
      publicClient: stubClient,
      walletClient: stubClient,
      prover: stubProver,
    });
    const usdc = c.pool("USDC");
    expect(usdc.asset).toBe("0x3600000000000000000000000000000000000000");
    expect(usdc.pool).toBe("0xC11C216C9C7A36848b1d4276d223160C8b51988f");
  });
});

describe("ShieldedNote serialize/deserialize", () => {
  const sample: ShieldedNote = {
    asset:  "0x3600000000000000000000000000000000000000",
    pool:   "0xC11C216C9C7A36848b1d4276d223160C8b51988f",
    scope:  13628782019290114344365157513531312776376936678300719745279061801973571818236n,
    value:  1_000_000n,
    nullifier: 74591808962260216386783556126704749546682638074336957498802926741155305792n,
    secret:    197312894565701329405294088597350363573990644087889043586731216879257071307n,
    label:     11097236335580572444082605369303149857974980065045955770983098469770772242089n,
    commitmentHash: 12672516525794921436632409537691999991315596533843980184927253581722696852125n,
  };

  test("round-trips through serialize/deserialize", () => {
    const s = PrivacyTradeClient.serializeNote(sample);
    const got = PrivacyTradeClient.deserializeNote(s);
    expect(got).toEqual(sample);
  });

  test("serialize produces JSON-parseable output", () => {
    const s = PrivacyTradeClient.serializeNote(sample);
    expect(() => JSON.parse(s)).not.toThrow();
    const o = JSON.parse(s);
    // bigints become decimal strings.
    expect(typeof o.value).toBe("string");
    expect(typeof o.nullifier).toBe("string");
    expect(o.value).toBe("1000000");
  });

  test("deserialize rejects malformed input (missing field)", () => {
    const bad = JSON.stringify({
      asset:  sample.asset,
      pool:   sample.pool,
      scope:  sample.scope.toString(),
      value:  sample.value.toString(),
      // nullifier omitted
      secret: sample.secret.toString(),
      label:  sample.label.toString(),
      commitmentHash: sample.commitmentHash.toString(),
    });
    expect(() => PrivacyTradeClient.deserializeNote(bad)).toThrow(/nullifier/);
  });

  test("deserialize rejects malformed input (wrong type)", () => {
    const bad = JSON.stringify({
      asset:  sample.asset,
      pool:   sample.pool,
      scope:  sample.scope.toString(),
      value:  1_000_000, // number, not string
      nullifier: sample.nullifier.toString(),
      secret:    sample.secret.toString(),
      label:     sample.label.toString(),
      commitmentHash: sample.commitmentHash.toString(),
    });
    expect(() => PrivacyTradeClient.deserializeNote(bad)).toThrow(/value/);
  });
});
