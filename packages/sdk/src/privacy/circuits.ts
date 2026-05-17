// SPDX-License-Identifier: Apache-2.0
//
// Circuit-artifact loader for the Privacy Pools Groth16 prover.
// Defines the interface the WithdrawalService consumes; the SDK ships
// without bundled .zkey/.wasm artifacts — consumers must wire a loader
// (e.g. fetch from a CDN / IPFS / local fs).
//
// Default URLs point at PSE's ceremony output (the same artifacts 0xbow
// ships in production). Override via the constructor for self-hosted
// mirrors or sandbox/testnet artifacts.

import { ErrorCode, PrivacyPoolError } from "./exceptions.js";

export enum CircuitName {
  Commitment = "commitment",
  Withdraw = "withdraw",
}

export interface CircuitsInterface {
  getWasm(circuit: CircuitName): Promise<Uint8Array>;
  getProvingKey(circuit: CircuitName): Promise<Uint8Array>;
  getVerificationKey(circuit: CircuitName): Promise<Uint8Array>;
}

/**
 * URL-based loader. Pass either explicit per-circuit URLs or use the
 * `baseUrl` form which expects the layout:
 *   {baseUrl}/{circuit}.wasm
 *   {baseUrl}/{circuit}.zkey
 *   {baseUrl}/{circuit}.vkey.json
 */
export interface UrlCircuitsConfig {
  baseUrl?: string;
  urls?: Partial<
    Record<CircuitName, { wasm: string; zkey: string; vkey: string }>
  >;
  fetch?: typeof fetch;
}

export class UrlCircuits implements CircuitsInterface {
  private readonly fetch: typeof fetch;

  constructor(private readonly cfg: UrlCircuitsConfig) {
    this.fetch = cfg.fetch ?? globalThis.fetch;
    if (!this.fetch) {
      throw new PrivacyPoolError(
        ErrorCode.CIRCUIT_NOT_INITIALIZED,
        "No fetch implementation available — supply config.fetch or run on a runtime with global fetch.",
      );
    }
  }

  private urlFor(c: CircuitName, kind: "wasm" | "zkey" | "vkey"): string {
    const explicit = this.cfg.urls?.[c]?.[kind];
    if (explicit) return explicit;
    if (!this.cfg.baseUrl) {
      throw new PrivacyPoolError(
        ErrorCode.CIRCUIT_NOT_INITIALIZED,
        `No baseUrl or explicit ${kind} URL for circuit '${c}'.`,
      );
    }
    const suffix = kind === "vkey" ? "vkey.json" : kind;
    return `${this.cfg.baseUrl.replace(/\/$/, "")}/${c}.${suffix}`;
  }

  private async getBin(url: string): Promise<Uint8Array> {
    const res = await this.fetch(url);
    if (!res.ok) {
      throw new PrivacyPoolError(
        ErrorCode.CIRCUIT_NOT_INITIALIZED,
        `Failed to fetch ${url}: HTTP ${res.status}`,
      );
    }
    const buf = await res.arrayBuffer();
    return new Uint8Array(buf);
  }

  getWasm(c: CircuitName): Promise<Uint8Array> {
    return this.getBin(this.urlFor(c, "wasm"));
  }
  getProvingKey(c: CircuitName): Promise<Uint8Array> {
    return this.getBin(this.urlFor(c, "zkey"));
  }
  getVerificationKey(c: CircuitName): Promise<Uint8Array> {
    return this.getBin(this.urlFor(c, "vkey"));
  }
}
