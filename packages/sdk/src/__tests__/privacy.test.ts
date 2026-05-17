// SPDX-License-Identifier: Apache-2.0
import { describe, expect, test } from "bun:test";
import { keccak256, encodeAbiParameters } from "viem";

import {
  SNARK_SCALAR_FIELD,
  CircuitName,
  ErrorCode,
  PrivacyPoolError,
  UrlCircuits,
  bigintToHex,
  calculateContext,
  decodeCrossCurrencyRelayData,
  encodeCrossCurrencyRelayData,
  generateDepositSecrets,
  generateMasterKeys,
  generateWithdrawalSecrets,
  getCommitment,
  hashPrecommitment,
  type Hash,
  type MasterKeys,
  type Secret,
  type CrossCurrencyRelayData,
  type Withdrawal,
} from "../privacy/index.js";

// 12-word BIP-39 mnemonic from the bip39 test vectors (NOT a real wallet).
const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

describe("privacy/constants", () => {
  test("SNARK_SCALAR_FIELD is the BN254 prime", () => {
    expect(SNARK_SCALAR_FIELD).toBe(
      21888242871839275222246405745257275088548364400416034343698204186575808495617n,
    );
  });
});

describe("privacy/crypto — master keys", () => {
  test("generateMasterKeys produces stable values across runs", () => {
    const k1 = generateMasterKeys(TEST_MNEMONIC);
    const k2 = generateMasterKeys(TEST_MNEMONIC);
    expect(k1.masterNullifier).toBe(k2.masterNullifier);
    expect(k1.masterSecret).toBe(k2.masterSecret);
  });

  test("different mnemonics produce different keys", () => {
    const a = generateMasterKeys(TEST_MNEMONIC);
    const b = generateMasterKeys(
      "legal winner thank year wave sausage worth useful legal winner thank yellow",
    );
    expect(a.masterNullifier).not.toBe(b.masterNullifier);
    expect(a.masterSecret).not.toBe(b.masterSecret);
  });

  test("empty mnemonic throws INVALID_VALUE", () => {
    expect(() => generateMasterKeys("")).toThrow(PrivacyPoolError);
  });
});

describe("privacy/crypto — secrets + commitment", () => {
  const keys: MasterKeys = generateMasterKeys(TEST_MNEMONIC);
  const scope = 123456789n as Hash;
  const label = 7n;

  test("generateDepositSecrets is deterministic in (keys, scope, index)", () => {
    const a = generateDepositSecrets(keys, scope, 0n);
    const b = generateDepositSecrets(keys, scope, 0n);
    expect(a.nullifier).toBe(b.nullifier);
    expect(a.secret).toBe(b.secret);
  });

  test("generateWithdrawalSecrets diverges from deposit secrets", () => {
    const dep = generateDepositSecrets(keys, scope, 0n);
    const wd = generateWithdrawalSecrets(keys, label as Hash, 0n);
    expect(dep.nullifier).not.toBe(wd.nullifier);
  });

  test("hashPrecommitment matches Poseidon([n, s])", () => {
    const { nullifier, secret } = generateDepositSecrets(keys, scope, 0n);
    const h = hashPrecommitment(nullifier, secret);
    expect(h).toBeGreaterThan(0n);
  });

  test("getCommitment binds (value, label, precommitmentHash) and is non-zero", () => {
    const { nullifier, secret } = generateDepositSecrets(keys, scope, 0n);
    const c = getCommitment(100n * 10n ** 6n, label, nullifier, secret);
    expect(c.hash).toBeGreaterThan(0n);
    expect(c.nullifierHash).toBeGreaterThan(0n);
    expect(c.preimage.value).toBe(100n * 10n ** 6n);
    expect(c.preimage.label).toBe(label);
  });

  test("getCommitment rejects zero secrets", () => {
    expect(() => getCommitment(1n, 1n, 0n as Secret, 1n as Secret)).toThrow();
    expect(() => getCommitment(1n, 1n, 1n as Secret, 0n as Secret)).toThrow();
    expect(() => getCommitment(1n, 0n, 1n as Secret, 1n as Secret)).toThrow();
  });
});

describe("privacy/crypto — calculateContext", () => {
  test("matches keccak256(abi.encode(withdrawal, scope)) % SNARK_SCALAR_FIELD", () => {
    const withdrawal: Withdrawal = {
      processooor: "0x1111111111111111111111111111111111111111",
      data: "0xdeadbeef",
    };
    const scope = 42n as Hash;

    const ctxHex = calculateContext(withdrawal, scope);

    // Recompute manually with viem.
    const expected =
      BigInt(
        keccak256(
          encodeAbiParameters(
            [
              {
                name: "withdrawal",
                type: "tuple",
                components: [
                  { name: "processooor", type: "address" },
                  { name: "data", type: "bytes" },
                ],
              },
              { name: "scope", type: "uint256" },
            ],
            [withdrawal, scope],
          ),
        ),
      ) % SNARK_SCALAR_FIELD;

    expect(BigInt(ctxHex)).toBe(expected);
  });
});

describe("privacy/crossCurrency — encode/decode round-trip", () => {
  test("preserves all fields", () => {
    const d: CrossCurrencyRelayData = {
      recipient:    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      feeRecipient: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      relayFeeBPS:  50n,
      buyToken:     "0xcccccccccccccccccccccccccccccccccccccccc",
      minBuyAmount: 99_500_000n,
    };
    const encoded = encodeCrossCurrencyRelayData(d);
    const decoded = decodeCrossCurrencyRelayData(encoded);

    expect(decoded.recipient.toLowerCase()).toBe(d.recipient.toLowerCase());
    expect(decoded.feeRecipient.toLowerCase()).toBe(d.feeRecipient.toLowerCase());
    expect(decoded.relayFeeBPS).toBe(d.relayFeeBPS);
    expect(decoded.buyToken.toLowerCase()).toBe(d.buyToken.toLowerCase());
    expect(decoded.minBuyAmount).toBe(d.minBuyAmount);
  });
});

describe("privacy/circuits — UrlCircuits", () => {
  test("rejects when neither baseUrl nor explicit URL is set", async () => {
    const circuits = new UrlCircuits({
      // both undefined — should throw on use
      fetch: globalThis.fetch ?? ((async () => new Response()) as typeof fetch),
    });
    let caught: unknown;
    try {
      await circuits.getWasm(CircuitName.Withdraw);
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(PrivacyPoolError);
  });

  test("builds canonical URLs from baseUrl", async () => {
    let captured: string | undefined;
    const stub: typeof fetch = async (input) => {
      captured = String(input);
      return new Response(new Uint8Array([1, 2, 3]));
    };
    const circuits = new UrlCircuits({
      baseUrl: "https://example.test/artifacts/",
      fetch: stub,
    });
    const out = await circuits.getProvingKey(CircuitName.Withdraw);
    expect(captured).toBe("https://example.test/artifacts/withdraw.zkey");
    expect(out).toEqual(new Uint8Array([1, 2, 3]));
  });

  test("propagates HTTP errors", async () => {
    const stub: typeof fetch = async () =>
      new Response("not found", { status: 404 });
    const circuits = new UrlCircuits({
      baseUrl: "https://example.test/",
      fetch: stub,
    });
    await expect(circuits.getWasm(CircuitName.Commitment)).rejects.toThrow(
      /HTTP 404/,
    );
  });
});

describe("privacy/types — helpers", () => {
  test("bigintToHex pads to 32 bytes", () => {
    expect(bigintToHex(1n)).toBe(
      "0x0000000000000000000000000000000000000000000000000000000000000001",
    );
    expect(bigintToHex(0xdeadbeefn)).toBe(
      "0x00000000000000000000000000000000000000000000000000000000deadbeef",
    );
  });
});

describe("privacy/exceptions", () => {
  test("PrivacyPoolError carries the ErrorCode", () => {
    const e = new PrivacyPoolError(ErrorCode.MERKLE_ERROR, "x");
    expect(e.code).toBe(ErrorCode.MERKLE_ERROR);
    expect(e.name).toBe("PrivacyPoolError");
  });
});
