/**
 * Tenderly Simulator API client.
 *
 * Wraps the v1 simulate + simulate-bundle endpoints with sensible defaults
 * (save=true, simulation_type=full) and types just enough to round-trip the
 * fields we actually use. Not exhaustive — intentionally narrow.
 *
 * Docs: https://docs.tenderly.co/simulations/single-simulations
 */
import { keccak256, encodeAbiParameters, toHex, type Hex, type Address } from "viem";

export type StateOverride = {
  /** Override the raw ETH balance (hex). */
  balance?: Hex;
  /** Override specific storage slots. Slot -> 32-byte hex value. */
  storage?: Record<Hex, Hex>;
  /** Override the deployed bytecode at this address. */
  code?: Hex;
};

export type SimulateRequest = {
  /** Chain id as a string, e.g. "84532". */
  network_id: string;
  from: Address;
  to: Address;
  /** ABI-encoded calldata. */
  input: Hex;
  /** Gas limit. Default 8M. */
  gas?: number;
  gas_price?: string;
  /** Native value sent with the call (wei, decimal string). */
  value?: string;
  /** Persist sim in Tenderly so it shows in the dashboard. */
  save?: boolean;
  save_if_fails?: boolean;
  /** "full" returns the complete call trace + decoded events. */
  simulation_type?: "full" | "quick" | "abi";
  /** Per-address state overrides (balance, storage, code). */
  state_objects?: Record<Address, StateOverride>;
  block_number?: number;
};

export type SimulateResponse = {
  simulation: {
    id: string;
    status: boolean;
    error_message?: string;
    /** Tenderly dashboard URL for the sim. Constructed if not returned. */
    url?: string;
  };
  transaction?: {
    status: boolean;
    error_message?: string;
    gas_used: number;
  };
  contracts?: unknown[];
  generated_access_list?: unknown[];
};

export class TenderlyClient {
  constructor(
    private accessKey: string,
    private account: string,
    private project: string,
  ) {}

  static fromEnv(env: Record<string, string | undefined>): TenderlyClient {
    const k = env.TENDERLY_ACCESS_KEY;
    const a = env.TENDERLY_ACCOUNT;
    const p = env.TENDERLY_PROJECT;
    if (!k || !a || !p) {
      throw new Error("TENDERLY_ACCESS_KEY / TENDERLY_ACCOUNT / TENDERLY_PROJECT missing");
    }
    return new TenderlyClient(k, a, p);
  }

  async simulate(req: SimulateRequest): Promise<SimulateResponse> {
    const body: SimulateRequest = {
      gas: 8_000_000,
      gas_price: "0",
      value: "0",
      save: true,
      save_if_fails: true,
      simulation_type: "full",
      ...req,
    };
    const url = `https://api.tenderly.co/api/v1/account/${this.account}/project/${this.project}/simulate`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "X-Access-Key": this.accessKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      throw new Error(`simulate ${res.status}: ${(await res.text()).slice(0, 400)}`);
    }
    const json = (await res.json()) as SimulateResponse;
    if (json.simulation?.id) {
      json.simulation.url = `https://dashboard.tenderly.co/${this.account}/${this.project}/simulator/${json.simulation.id}`;
    }
    return json;
  }

  async simulateBundle(reqs: SimulateRequest[]): Promise<SimulateResponse[]> {
    const body = {
      simulations: reqs.map((r) => ({
        gas: 8_000_000,
        gas_price: "0",
        value: "0",
        save: true,
        save_if_fails: true,
        simulation_type: "full" as const,
        ...r,
      })),
    };
    const url = `https://api.tenderly.co/api/v1/account/${this.account}/project/${this.project}/simulate-bundle`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "X-Access-Key": this.accessKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      throw new Error(`simulate-bundle ${res.status}: ${(await res.text()).slice(0, 400)}`);
    }
    const json = (await res.json()) as { simulation_results: SimulateResponse[] };
    return json.simulation_results.map((r) => {
      if (r.simulation?.id) {
        r.simulation.url = `https://dashboard.tenderly.co/${this.account}/${this.project}/simulator/${r.simulation.id}`;
      }
      return r;
    });
  }
}

/**
 * Compute the storage slot of `mapping(address => uint256)` at `mappingSlot`
 * for the given holder. Used to override an ERC-20 `_balances[holder]`.
 */
export function balanceSlot(holder: Address, mappingSlot: number): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [holder, BigInt(mappingSlot)],
    ),
  );
}

/**
 * Compute the storage slot for `mapping(address => mapping(address => uint256))`
 * at `mappingSlot`. Used to override an ERC-20 `_allowed[owner][spender]`.
 */
export function allowanceSlot(owner: Address, spender: Address, mappingSlot: number): Hex {
  const inner = keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [owner, BigInt(mappingSlot)],
    ),
  );
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "bytes32" }],
      [spender, inner],
    ),
  );
}

export function valueHex(amount: bigint): Hex {
  return toHex(amount, { size: 32 });
}
