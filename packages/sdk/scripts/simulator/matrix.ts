/**
 * Declarative test-case definitions for the Tenderly simulator suite.
 *
 * Each case is a self-contained `SimulateRequest` plus an `expect` clause.
 * The runner asserts the result against `expect` and reports failures with
 * dashboard URLs.
 */
import { encodeFunctionData, parseAbi, type Address, type Hex } from "viem";
import { balanceSlot, valueHex as hex32, type SimulateRequest } from "./client.js";
import { PERSONAS, personaState, type Persona } from "./personas.js";

export type Expect =
  | { kind: "pass" }
  | { kind: "revert" }
  | { kind: "revert-contains"; needle: string };

export type TestCase = {
  /** category.id format (e.g. "A.eth-sepolia.whale.large"). */
  id: string;
  /** Human description for the report. */
  description: string;
  /** The single tx the assertion is run against. When `bundle` is present
   *  this is the LAST entry of the bundle (the one the assertion checks). */
  request: SimulateRequest;
  /** Optional multi-step setup. When set the runner uses simulate-bundle
   *  and asserts against the final entry's result. */
  bundle?: SimulateRequest[];
  expect: Expect;
};

type SpokeManifest = {
  network: string;
  chainId: number;
  contracts: { FxSpoke: Address };
  external: { USDC: Address };
};

const SPOKE_ABI = parseAbi([
  "function enterHub(address token, uint256 amount, address beneficiary, bytes hubCalldata) external payable returns (bytes32)",
]);

const ERC4626_ABI = parseAbi([
  "function deposit(uint256 assets, address receiver) external returns (uint256)",
  "function redeem(uint256 shares, address receiver, address owner) external returns (uint256)",
  "function maxDeposit(address) external view returns (uint256)",
]);

/// 200 USDC (6 decimals) — used as the "small_deposit" amount in category A.
const SMALL_DEPOSIT = 200_000_000n;
/// 100,000 USDC — "large_deposit". Only `whale` covers this.
const LARGE_DEPOSIT = 100_000_000_000n;

/// Category A: per spoke chain, for each persona, simulate two enterHub
/// deposits. Expected outcome depends on persona's pre-loaded balance.
export function categoryA(spokes: SpokeManifest[]): TestCase[] {
  const out: TestCase[] = [];
  for (const s of spokes) {
    for (const personaKey of ["whale", "mid", "small", "empty"] as const) {
      for (const sizeKey of ["small", "large"] as const) {
        const p = PERSONAS[personaKey];
        const amount = sizeKey === "small" ? SMALL_DEPOSIT : LARGE_DEPOSIT;

        const input = encodeFunctionData({
          abi: SPOKE_ABI,
          functionName: "enterHub",
          args: [s.external.USDC, amount, p.address, "0x"],
        });

        const expect: Expect =
          amount <= p.usdc ? { kind: "pass" } : { kind: "revert" };

        out.push({
          id: `A.${s.network}.${personaKey}.${sizeKey}`,
          description: `${s.network} | ${personaKey} | deposit ${amount / 1_000_000n} USDC | expect ${expect.kind}`,
          request: {
            network_id: String(s.chainId),
            from: p.address,
            to: s.contracts.FxSpoke,
            input,
            state_objects: personaState(p, s.external.USDC, s.contracts.FxSpoke),
          },
          expect,
        });
      }
    }
  }
  return out;
}

type HubManifest = {
  network: string;
  chainId: number;
  contracts: {
    FxOracle: Address;
    FxMarketRegistry: Address;
    FxReceiptUSDC: Address;
    FxReceiptEURC: Address;
  };
  external: { USDC: Address; EURC: Address };
};

/// Category B (subset implemented in Drop 2): ERC-4626 mint + redeem on the
/// hub's FxReceiptUSDC and FxReceiptEURC. 4 personas × 4 flows = 16 cases.
/// (Borrow + swap flows ship in Drop 3 — they need oracle freshness state
/// overrides that warrant their own helper.)
export function categoryB(hub: HubManifest): TestCase[] {
  const out: TestCase[] = [];

  for (const personaKey of ["whale", "mid", "small", "empty"] as const) {
    const p = PERSONAS[personaKey];

    // Mint fxUSDC: deposit USDC into FxReceiptUSDC.
    {
      const amount = p.usdc > 0n ? p.usdc / 2n : 100_000_000n;
      const input = encodeFunctionData({
        abi: ERC4626_ABI,
        functionName: "deposit",
        args: [amount, p.address],
      });
      const expect: Expect = amount <= p.usdc ? { kind: "pass" } : { kind: "revert" };
      out.push({
        id: `B.mint-fxUSDC.${personaKey}`,
        description: `mint fxUSDC | ${personaKey} | deposit ${amount / 1_000_000n} USDC | expect ${expect.kind}`,
        request: {
          network_id: String(hub.chainId),
          from: p.address,
          to: hub.contracts.FxReceiptUSDC,
          input,
          state_objects: personaState(p, hub.external.USDC, hub.contracts.FxReceiptUSDC, hub.external.EURC),
        },
        expect,
      });
    }

    // Mint fxEURC: deposit EURC into FxReceiptEURC.
    {
      const amount = p.eurc > 0n ? p.eurc / 2n : 100_000_000n;
      const input = encodeFunctionData({
        abi: ERC4626_ABI,
        functionName: "deposit",
        args: [amount, p.address],
      });
      const expect: Expect = amount <= p.eurc ? { kind: "pass" } : { kind: "revert" };
      out.push({
        id: `B.mint-fxEURC.${personaKey}`,
        description: `mint fxEURC | ${personaKey} | deposit ${amount / 1_000_000n} EURC | expect ${expect.kind}`,
        request: {
          network_id: String(hub.chainId),
          from: p.address,
          to: hub.contracts.FxReceiptEURC,
          input,
          state_objects: personaState(p, hub.external.USDC, hub.contracts.FxReceiptEURC, hub.external.EURC),
        },
        expect,
      });
    }

    // Redeem fxUSDC: pre-load `_balances[persona]` on the receipt. Without
    // also overriding `_totalSupply` (slot 2) and the vault's reported
    // `totalAssets()` (a Morpho-derived view), ERC-4626's
    //   assets = (shares * totalAssets()) / totalSupply
    // hits division by zero → arithmetic underflow/overflow revert. This is
    // expected and documents a known limitation of pure state-override
    // testing. Drop 3 replaces these cases with a deposit+redeem bundle so
    // the vault's bookkeeping is consistent.
    {
      const shares = p.usdc;
      const input = encodeFunctionData({
        abi: ERC4626_ABI,
        functionName: "redeem",
        args: [shares > 0n ? shares / 4n : 1_000_000n, p.address, p.address],
      });
      const expect: Expect = { kind: "revert" };
      out.push({
        id: `B.redeem-fxUSDC.${personaKey}`,
        description: `redeem fxUSDC | ${personaKey} | expect revert (totalSupply not seeded; Drop 3 fixes via deposit+redeem bundle)`,
        request: {
          network_id: String(hub.chainId),
          from: p.address,
          to: hub.contracts.FxReceiptUSDC,
          input,
          state_objects: shares > 0n
            ? {
                [hub.contracts.FxReceiptUSDC]: {
                  storage: {
                    // ERC20 _balances at slot 0 of FxReceipt (inherited from OZ ERC20).
                    [balanceSlot(p.address, 0)]: hex32(shares),
                  },
                },
              }
            : {},
        },
        expect,
      });
    }

    // Redeem fxEURC — same totalSupply caveat as fxUSDC.
    {
      const shares = p.eurc;
      const input = encodeFunctionData({
        abi: ERC4626_ABI,
        functionName: "redeem",
        args: [shares > 0n ? shares / 4n : 1_000_000n, p.address, p.address],
      });
      const expect: Expect = { kind: "revert" };
      out.push({
        id: `B.redeem-fxEURC.${personaKey}`,
        description: `redeem fxEURC | ${personaKey} | expect revert (Drop 3: deposit+redeem bundle)`,
        request: {
          network_id: String(hub.chainId),
          from: p.address,
          to: hub.contracts.FxReceiptEURC,
          input,
          state_objects: shares > 0n
            ? {
                [hub.contracts.FxReceiptEURC]: {
                  storage: {
                    [balanceSlot(p.address, 0)]: hex32(shares),
                  },
                },
              }
            : {},
        },
        expect,
      });
    }
  }
  return out;
}

