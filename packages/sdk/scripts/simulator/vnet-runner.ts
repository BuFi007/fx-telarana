// SPDX-License-Identifier: AGPL-3.0-only
/**
 * Drop 9 — primed Virtual TestNet routing for the simulator matrix.
 *
 * Wraps the vnet's admin RPC behind the same `simulate` / `simulateBundle`
 * surface that `TenderlyClient` exposes, so the runner can swap backends by
 * flipping `TENDERLY_USE_PRIMED_VNET=1` without touching test definitions.
 *
 * We use `tenderly_simulateBundle` (admin RPC) for everything — single-tx
 * cases get wrapped in a one-element bundle. It supports per-tx
 * `stateOverrides`, preserves state across the array, and returns the same
 * `status` + `gasUsed` + trace + error shape we already consume.
 *
 * Probe results (May 2026):
 *   `tenderly_simulateBundle`      -> available, accepts [[txs], blockTag]
 *   `tenderly_simulateTransaction` -> available, single tx
 *   `tenderly_simulateTransactions`-> NOT available
 *
 * Pre-flight: `assertReady()` reads `eth_chainId` + the whale's USDC
 * balance and aborts if the vnet isn't primed how the matrix expects.
 *
 * For every case routed through the vnet we still pass `stateOverrides`
 * (translated from the existing `state_objects` map) — the vnet's primed
 * balances cover the whale persona, but the other personas (mid, small,
 * empty) still need per-case storage overrides on each call.
 */
import { createPublicClient, http, type Address, type Hex } from "viem";
import type {
  SimulateRequest,
  SimulateResponse,
  StateOverride,
} from "./client.js";

type TenderlyBundleTx = {
  from: Address;
  to: Address;
  data: Hex;
  gas?: Hex;
  gasPrice?: Hex;
  value?: Hex;
  stateOverrides?: Record<Address, StateOverride>;
};

type TenderlyTraceEntry = {
  type?: string;
  from?: string;
  to?: string;
  error?: string;
  errorReason?: string;
  subtraces?: number;
  traceAddress?: number[];
};

type TenderlyBundleResult = {
  status: boolean;
  gasUsed: Hex;
  cumulativeGasUsed?: Hex;
  blockNumber?: Hex;
  trace?: TenderlyTraceEntry[];
  logs?: unknown[];
};

type BundleEnvelope = {
  result?: TenderlyBundleResult[];
  error?: { code: number; message: string };
};

function toHexQ(n: number | bigint | string | undefined, fallback: bigint): Hex {
  const v = n === undefined || n === null ? fallback : BigInt(n as any);
  return `0x${v.toString(16)}` as Hex;
}

function reqToBundleTx(req: SimulateRequest): TenderlyBundleTx {
  const tx: TenderlyBundleTx = {
    from: req.from,
    to: req.to,
    data: req.input,
    gas: toHexQ(req.gas, 8_000_000n),
    gasPrice: toHexQ(req.gas_price ?? "0", 0n),
    value: toHexQ(req.value ?? "0", 0n),
  };
  if (req.state_objects && Object.keys(req.state_objects).length > 0) {
    tx.stateOverrides = req.state_objects;
  }
  return tx;
}

function extractRevertReason(trace: TenderlyTraceEntry[] | undefined): string {
  if (!trace) return "";
  // Walk depth-first; inner frames carry the precise revert reason.
  let bestReason = "";
  let topError = "";
  for (const t of trace) {
    if (t.errorReason && !bestReason) bestReason = t.errorReason;
    if (t.error && !topError) topError = t.error;
  }
  return bestReason || topError;
}

function adaptResult(
  rpcUrl: string,
  chainId: number,
  id: number,
  res: TenderlyBundleResult,
): SimulateResponse {
  const status = !!res.status;
  const gas = res.gasUsed ? Number(BigInt(res.gasUsed)) : 0;
  const reason = status ? "" : extractRevertReason(res.trace);
  const sim: SimulateResponse["simulation"] = {
    id: `vnet:${chainId}:${id}`,
    status,
    error_message: reason || undefined,
    // No dashboard URL for vnet runs — use the public RPC slug so reports
    // still surface a recognisable backend identifier per row.
    url: `vnet:${chainId}`,
  };
  return {
    simulation: sim,
    transaction: {
      status,
      error_message: reason || undefined,
      gas_used: gas,
    },
  };
}

const ERC20_BALANCE_OF_SELECTOR = "0x70a08231"; // balanceOf(address)
function balanceOfCall(holder: Address): Hex {
  const padded = holder.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  return `${ERC20_BALANCE_OF_SELECTOR}${padded}` as Hex;
}

export class VnetRunner {
  readonly chainId: number;
  readonly publicRpc: string;
  readonly adminRpc: string;
  private callId = 0;

  constructor(opts: {
    chainId: number;
    publicRpc: string;
    adminRpc: string;
  }) {
    this.chainId = opts.chainId;
    this.publicRpc = opts.publicRpc;
    this.adminRpc = opts.adminRpc;
  }

  /** Returns true if this case's `network_id` matches the vnet's chainId. */
  canHandle(networkId: string | number): boolean {
    return Number(networkId) === this.chainId;
  }

  /** Reads the vnet chainId via `eth_chainId`. */
  async readChainId(): Promise<number> {
    const r = await this.rpc(this.publicRpc, "eth_chainId", []);
    if (typeof r !== "string") throw new Error(`eth_chainId returned ${JSON.stringify(r)}`);
    return Number(BigInt(r));
  }

  /** Reads `balanceOf(account)` against the given ERC-20 contract. */
  async readErc20Balance(token: Address, account: Address): Promise<bigint> {
    const r = await this.rpc(this.publicRpc, "eth_call", [
      { to: token, data: balanceOfCall(account) },
      "latest",
    ]);
    if (typeof r !== "string") {
      throw new Error(`eth_call(balanceOf) returned ${JSON.stringify(r)}`);
    }
    return BigInt(r);
  }

  /**
   * Pre-flight gate: confirms vnet is reachable, chainId matches expectation,
   * and the whale persona has a non-zero USDC balance on the vnet.
   *
   * If `expectedChainId` is provided we require an exact match; otherwise we
   * just record what the vnet reports and let per-case fallback handle
   * mismatches downstream.
   */
  async assertReady(opts: {
    expectedChainId?: number;
    whaleUsdc?: { token: Address; account: Address; minBalance: bigint };
  }): Promise<{ chainId: number; whaleBalance: bigint | null }> {
    const chainId = await this.readChainId();
    if (opts.expectedChainId !== undefined && chainId !== opts.expectedChainId) {
      throw new Error(
        `vnet chainId mismatch: expected ${opts.expectedChainId}, got ${chainId}. ` +
          `Re-run scripts/tenderly-prime-vnet.sh against the right chain or unset TENDERLY_USE_PRIMED_VNET.`,
      );
    }
    let whaleBalance: bigint | null = null;
    if (opts.whaleUsdc) {
      whaleBalance = await this.readErc20Balance(opts.whaleUsdc.token, opts.whaleUsdc.account);
      if (whaleBalance < opts.whaleUsdc.minBalance) {
        throw new Error(
          `vnet pre-flight: whale ${opts.whaleUsdc.account} has ${whaleBalance} USDC ` +
            `(< ${opts.whaleUsdc.minBalance}). Re-run scripts/tenderly-prime-vnet.sh.`,
        );
      }
    }
    return { chainId, whaleBalance };
  }

  /** Same shape as `TenderlyClient.simulate`. */
  async simulate(req: SimulateRequest): Promise<SimulateResponse> {
    const [out] = await this.simulateBundle([req]);
    return out;
  }

  /**
   * Same shape as `TenderlyClient.simulateBundle`. We translate the array
   * into a single `tenderly_simulateBundle` call so the vnet executes the
   * txs sequentially with shared state.
   */
  async simulateBundle(reqs: SimulateRequest[]): Promise<SimulateResponse[]> {
    if (reqs.length === 0) return [];
    const bundle = reqs.map(reqToBundleTx);
    const id = ++this.callId;
    const r = await this.rpc(this.adminRpc, "tenderly_simulateBundle", [bundle, "latest"]);
    if (!Array.isArray(r)) {
      throw new Error(`tenderly_simulateBundle returned non-array: ${JSON.stringify(r).slice(0, 200)}`);
    }
    return (r as TenderlyBundleResult[]).map((bundleRes, idx) =>
      adaptResult(this.adminRpc, this.chainId, id * 100 + idx, bundleRes),
    );
  }

  private async rpc(url: string, method: string, params: unknown[]): Promise<unknown> {
    const body = JSON.stringify({ jsonrpc: "2.0", method, params, id: ++this.callId });
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });
    if (!res.ok) {
      throw new Error(`${method} HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
    }
    const env = (await res.json()) as BundleEnvelope & { result?: unknown };
    if (env.error) {
      throw new Error(`${method} RPC error ${env.error.code}: ${env.error.message}`);
    }
    return env.result;
  }

  static fromEnv(env: Record<string, string | undefined>): VnetRunner | null {
    if (env.TENDERLY_USE_PRIMED_VNET !== "1") return null;
    const publicRpc = env.TENDERLY_PRIMED_VNET_PUBLIC_RPC;
    const adminRpc = env.TENDERLY_PRIMED_VNET_ADMIN_RPC;
    const chainIdRaw = env.TENDERLY_PRIMED_VNET_CHAIN_ID;
    if (!publicRpc || !adminRpc) return null;
    const chainId = chainIdRaw ? Number(chainIdRaw) : NaN;
    if (!Number.isFinite(chainId)) {
      throw new Error(
        "TENDERLY_USE_PRIMED_VNET=1 but TENDERLY_PRIMED_VNET_CHAIN_ID is missing/non-numeric. " +
          "Re-run scripts/tenderly-prime-vnet.sh to repopulate .env.local.",
      );
    }
    return new VnetRunner({ chainId, publicRpc, adminRpc });
  }
}

/**
 * Helper for the runner. Surfaces a viem PublicClient if downstream code
 * wants to read state directly (e.g. dashboard rendering).
 */
export function vnetPublicClient(publicRpc: string, chainId: number) {
  return createPublicClient({
    transport: http(publicRpc),
    chain: {
      id: chainId,
      name: `tenderly-vnet-${chainId}`,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [publicRpc] } },
    } as any,
  });
}
