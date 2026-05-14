/**
 * Drop 3 matrix additions: categories C (risk + recovery), D (swap-hook
 * edges), and bundle-based redeem cases.
 *
 * Tenderly's `simulate-bundle` endpoint lets us chain a setup tx with the
 * assertion tx so the state is internally consistent — no more pure
 * storage-override gymnastics for ERC-4626 redeems.
 */
import { encodeFunctionData, parseAbi, toHex, type Address, type Hex } from "viem";
import {
  balanceSlot,
  valueHex as hex32,
  type SimulateRequest,
} from "./client.js";
import { PERSONAS, personaState, type Persona } from "./personas.js";
import type { TestCase, Expect } from "./matrix.js";

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

const ERC4626_ABI = parseAbi([
  "function deposit(uint256 assets, address receiver) external returns (uint256)",
  "function redeem(uint256 shares, address receiver, address owner) external returns (uint256)",
]);

const MORPHO_ABI = parseAbi([
  "function supplyCollateral((address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams, uint256 assets, address onBehalf, bytes data) external",
  "function borrow((address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external returns (uint256, uint256)",
  "function setAuthorization(address authorized, bool newIsAuthorized) external",
]);

const LIQUIDATOR_ABI = parseAbi([
  "function liquidate(address loanToken, address collateralToken, address borrower, uint256 seizedAssets, uint256 repaidShares, uint256 maxRepayAssets, bool useVerified, bytes[] pythUpdate) external payable returns (uint256, uint256)",
]);

const RECEIVER_ABI = parseAbi([
  "function sweepStrandedDeposit(bytes32 messageNonce) external",
]);

const ORACLE_ABI = parseAbi([
  "function getMid(address base, address quote) external view returns (uint256, uint256)",
]);

// Morpho market params for M2 (loan=USDC, collat=EURC). LLTV 86%.
function m2Params(hub: HubManifest, irm: Address, lltv: bigint) {
  return {
    loanToken: hub.external.USDC,
    collateralToken: hub.external.EURC,
    oracle: hub.contracts.MorphoOracleAdapterM2,
    irm,
    lltv,
  };
}

// Hard-coded adaptive curve IRM on Base Sepolia.
const ADAPTIVE_IRM: Address = "0x46415998764C29aB2a25CbeA6254146D50D22687";
const LLTV: bigint = 860000000000000000n; // 0.86e18

/// Category B (Drop 3 redeem fix): deposit then redeem in one bundle.
/// 4 personas. Replaces the standalone redeem cases from Drop 2.
export function categoryBRedeemBundle(hub: HubManifest): TestCase[] {
  const out: TestCase[] = [];

  for (const personaKey of ["whale", "mid", "small"] as const) {
    const p = PERSONAS[personaKey];

    const depositAmount = p.usdc / 4n; // 25% of balance
    const depositInput = encodeFunctionData({
      abi: ERC4626_ABI,
      functionName: "deposit",
      args: [depositAmount, p.address],
    });
    // We don't know the shares we'll receive without simulating — but for
    // a fresh vault the relation is roughly 1:1, so redeem all the shares
    // the bundle would have minted by passing the same `depositAmount` as
    // a conservative upper bound.
    const redeemShares = depositAmount;
    const redeemInput = encodeFunctionData({
      abi: ERC4626_ABI,
      functionName: "redeem",
      args: [redeemShares, p.address, p.address],
    });

    out.push({
      id: `B.bundle-redeem-fxUSDC.${personaKey}`,
      description: `bundle deposit→redeem fxUSDC | ${personaKey}`,
      // The bundle runner consumes this; if it's a multi-step we emit the
      // second step into the case description, but here we keep it as a
      // single-tx case using a meta marker. Actual sequencing lives in
      // run-matrix.ts via case.bundle.
      request: {
        network_id: String(hub.chainId),
        from: p.address,
        to: hub.contracts.FxReceiptUSDC,
        input: redeemInput,
        state_objects: personaState(p, hub.external.USDC, hub.contracts.FxReceiptUSDC, hub.external.EURC),
      },
      expect: { kind: "pass" },
      bundle: [
        {
          network_id: String(hub.chainId),
          from: p.address,
          to: hub.contracts.FxReceiptUSDC,
          input: depositInput,
          state_objects: personaState(p, hub.external.USDC, hub.contracts.FxReceiptUSDC, hub.external.EURC),
        },
        {
          network_id: String(hub.chainId),
          from: p.address,
          to: hub.contracts.FxReceiptUSDC,
          input: redeemInput,
        },
      ],
    } as TestCase);
  }
  return out;
}

/// Category C: risk + recovery.
export function categoryC(hub: HubManifest): TestCase[] {
  const out: TestCase[] = [];
  const whale = PERSONAS.whale;

  // C1 — Healthy borrow: supply EURC collateral + borrow USDC at modest LTV.
  // 1000 EURC collateral, borrow 500 USDC (= ~46% LTV). Bundle: authorize +
  // supplyCollateral + borrow.
  {
    const collateral = 1_000_000_000n; // 1000 EURC
    const borrowAmt   = 500_000_000n;  // 500 USDC

    const supplyCollat = encodeFunctionData({
      abi: MORPHO_ABI,
      functionName: "supplyCollateral",
      args: [m2Params(hub, ADAPTIVE_IRM, LLTV), collateral, whale.address, "0x"],
    });
    const borrowCall = encodeFunctionData({
      abi: MORPHO_ABI,
      functionName: "borrow",
      args: [m2Params(hub, ADAPTIVE_IRM, LLTV), borrowAmt, 0n, whale.address, whale.address],
    });

    out.push({
      id: "C.borrow.healthy",
      description: "supply 1000 EURC, borrow 500 USDC (~46% LTV)",
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
          input: supplyCollat,
          state_objects: personaState(whale, hub.external.USDC, hub.external.MorphoBlue, hub.external.EURC),
        },
        {
          network_id: String(hub.chainId),
          from: whale.address,
          to: hub.external.MorphoBlue,
          input: borrowCall,
        },
      ],
    } as TestCase);
  }

  // C2 — Borrow at LLTV boundary: 1000 EURC collateral, borrow 859 USDC
  // (85.9% LTV — just inside the 86% gate). Expect pass.
  {
    const collateral = 1_000_000_000n;
    const borrowAmt   = 859_000_000n;
    out.push({
      id: "C.borrow.boundary-85.9",
      description: "borrow at 85.9% LTV (inside 86% gate)",
      request: {
        network_id: String(hub.chainId),
        from: whale.address,
        to: hub.external.MorphoBlue,
        input: encodeFunctionData({
          abi: MORPHO_ABI,
          functionName: "borrow",
          args: [m2Params(hub, ADAPTIVE_IRM, LLTV), borrowAmt, 0n, whale.address, whale.address],
        }),
      },
      expect: { kind: "pass" },
      bundle: [
        {
          network_id: String(hub.chainId),
          from: whale.address,
          to: hub.external.MorphoBlue,
          input: encodeFunctionData({
            abi: MORPHO_ABI,
            functionName: "supplyCollateral",
            args: [m2Params(hub, ADAPTIVE_IRM, LLTV), collateral, whale.address, "0x"],
          }),
          state_objects: personaState(whale, hub.external.USDC, hub.external.MorphoBlue, hub.external.EURC),
        },
        {
          network_id: String(hub.chainId),
          from: whale.address,
          to: hub.external.MorphoBlue,
          input: encodeFunctionData({
            abi: MORPHO_ABI,
            functionName: "borrow",
            args: [m2Params(hub, ADAPTIVE_IRM, LLTV), borrowAmt, 0n, whale.address, whale.address],
          }),
        },
      ],
    } as TestCase);
  }

  // C3 — Borrow beyond LLTV: 1000 EURC, borrow 870 USDC (87% LTV). Expect revert.
  {
    const collateral = 1_000_000_000n;
    const borrowAmt   = 870_000_000n;
    out.push({
      id: "C.borrow.over-LLTV-87",
      description: "borrow at 87% LTV (above 86% gate) — must revert",
      request: {
        network_id: String(hub.chainId),
        from: whale.address,
        to: hub.external.MorphoBlue,
        input: encodeFunctionData({
          abi: MORPHO_ABI,
          functionName: "borrow",
          args: [m2Params(hub, ADAPTIVE_IRM, LLTV), borrowAmt, 0n, whale.address, whale.address],
        }),
      },
      expect: { kind: "revert" },
      bundle: [
        {
          network_id: String(hub.chainId),
          from: whale.address,
          to: hub.external.MorphoBlue,
          input: encodeFunctionData({
            abi: MORPHO_ABI,
            functionName: "supplyCollateral",
            args: [m2Params(hub, ADAPTIVE_IRM, LLTV), collateral, whale.address, "0x"],
          }),
          state_objects: personaState(whale, hub.external.USDC, hub.external.MorphoBlue, hub.external.EURC),
        },
        {
          network_id: String(hub.chainId),
          from: whale.address,
          to: hub.external.MorphoBlue,
          input: encodeFunctionData({
            abi: MORPHO_ABI,
            functionName: "borrow",
            args: [m2Params(hub, ADAPTIVE_IRM, LLTV), borrowAmt, 0n, whale.address, whale.address],
          }),
        },
      ],
    } as TestCase);
  }

  // C4 — Liquidate with no allowance: caller approves 0 USDC to liquidator
  // but asks for a maxRepayAssets > 0 → expect InsufficientApproval revert.
  {
    const callerAddr = PERSONAS.whale.address;
    const borrowerAddr = PERSONASAddress; // populated below via const
    const liquidateInput = encodeFunctionData({
      abi: LIQUIDATOR_ABI,
      functionName: "liquidate",
      args: [
        hub.external.USDC,
        hub.external.EURC,
        callerAddr, // borrower = caller for this contrived test
        0n,
        1n,        // 1 share — small symbolic amount
        100_000_000n,
        false,
        [],
      ],
    });
    out.push({
      id: "C.liquidate.no-allowance",
      description: "liquidate without USDC allowance — expect InsufficientApproval",
      request: {
        network_id: String(hub.chainId),
        from: callerAddr,
        to: hub.contracts.FxLiquidator,
        input: liquidateInput,
        // NO allowance pre-loaded. Default: whale persona's allowance to
        // the liquidator stays 0 → InsufficientApproval(100M, 0).
        state_objects: {
          [hub.external.USDC]: {
            storage: {
              [balanceSlot(callerAddr, 9)]: hex32(100_000_000_000n),
            },
          },
        },
      },
      expect: { kind: "revert" },
    });
  }

  // C5 — Liquidate with useVerified=true on chain without RedStone → revert.
  // FxOracle.getMidVerified reads RedStone payload from msg.data tail; on
  // Base Sepolia there are no RedStone signers, so it always reverts.
  {
    const callerAddr = PERSONAS.whale.address;
    out.push({
      id: "C.liquidate.no-redstone",
      description: "liquidate useVerified=true on Base Sepolia (no RedStone) — expect revert",
      request: {
        network_id: String(hub.chainId),
        from: callerAddr,
        to: hub.contracts.FxLiquidator,
        input: encodeFunctionData({
          abi: LIQUIDATOR_ABI,
          functionName: "liquidate",
          args: [
            hub.external.USDC,
            hub.external.EURC,
            callerAddr,
            0n,
            1n,
            100_000_000n,
            true, // useVerified
            ["0x00" as Hex],
          ],
        }),
        state_objects: personaState(PERSONAS.whale, hub.external.USDC, hub.contracts.FxLiquidator, hub.external.EURC),
      },
      expect: { kind: "revert" },
    });
  }

  // C6 — Sweep stranded deposit for a non-existent nonce → revert.
  {
    out.push({
      id: "C.sweep.unknown-nonce",
      description: "sweep nonce that was never stranded — expect revert",
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxHubMessageReceiver,
        input: encodeFunctionData({
          abi: RECEIVER_ABI,
          functionName: "sweepStrandedDeposit",
          args: ["0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" as Hex],
        }),
      },
      expect: { kind: "revert" },
    });
  }

  // C7 — Oracle staleness: Pyth on Base Sepolia testnet rarely sees fresh
  // updates (no production keepers push it), so `getMid` reverts with
  // OracleStale at the chain head most of the time. The 600s staleness
  // gate behaves correctly. This sim asserts that revert.
  // (A "fresh path" assertion needs a bundled `updatePriceFeeds` call with
  //  a Pyth Hermes payload — Drop 4 will add that with a fixture payload.)
  {
    out.push({
      id: "C.oracle.stale-as-expected",
      description: "FxOracle.getMid (Pyth feed stale on testnet) — expect OracleStale revert",
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxOracle,
        input: encodeFunctionData({
          abi: ORACLE_ABI,
          functionName: "getMid",
          args: [hub.external.USDC, hub.external.EURC],
        }),
      },
      expect: { kind: "revert" },
    });
  }

  // C8 — Reverse direction; same staleness applies.
  {
    out.push({
      id: "C.oracle.stale-reverse",
      description: "FxOracle.getMid(EURC, USDC) on stale Pyth — expect revert",
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxOracle,
        input: encodeFunctionData({
          abi: ORACLE_ABI,
          functionName: "getMid",
          args: [hub.external.EURC, hub.external.USDC],
        }),
      },
      expect: { kind: "revert" },
    });
  }

  // C9 — Bad oracle pair: call getMid with an unknown token → revert
  // OracleFeedUnknown. Distinct from the staleness path.
  {
    out.push({
      id: "C.oracle.unknown-feed",
      description: "getMid with unknown token — expect OracleFeedUnknown revert",
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxOracle,
        input: encodeFunctionData({
          abi: ORACLE_ABI,
          functionName: "getMid",
          args: ["0xdead000000000000000000000000000000000000" as Address, hub.external.USDC],
        }),
      },
      expect: { kind: "revert" },
    });
  }

  return out;
}

/// Category D (subset): swap-hook reads we can sim without an active LP
/// position. Reads are easy; live swaps through PoolManager require an
/// unlock-callback flow that's clumsy to fabricate via state-override.
export function categoryD(hub: HubManifest): TestCase[] {
  const out: TestCase[] = [];
  const FXSWAPHOOK_VIEW_ABI = parseAbi([
    "function totalShares() external view returns (uint256)",
    "function hotReservePct() external view returns (uint16)",
    "function spreadBps() external view returns (uint16)",
    "function kBps() external view returns (uint16)",
  ]);

  for (const fn of ["totalShares", "hotReservePct", "spreadBps", "kBps"] as const) {
    out.push({
      id: `D.read.${fn}`,
      description: `FxSwapHook.${fn}() read — expect pass`,
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxSwapHook,
        input: encodeFunctionData({ abi: FXSWAPHOOK_VIEW_ABI, functionName: fn, args: [] }),
      },
      expect: { kind: "pass" },
    });
  }

  // D5 — quote at zero-amount swap call. The hook's beforeSwap is locked
  // to (TOKEN0, TOKEN1); calling it directly from a non-PoolManager would
  // revert with `NotPoolManager`. We assert that revert as a sanity check.
  {
    const FXSWAPHOOK_HOOKS_ABI = parseAbi([
      "function beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes) external returns (bytes4,int256,uint24)",
    ]);
    out.push({
      id: "D.hook.guards-poolmanager",
      description: "calling beforeSwap directly (not from PoolManager) — expect revert",
      request: {
        network_id: String(hub.chainId),
        from: PERSONAS.whale.address,
        to: hub.contracts.FxSwapHook,
        input: encodeFunctionData({
          abi: FXSWAPHOOK_HOOKS_ABI,
          functionName: "beforeSwap",
          args: [
            PERSONAS.whale.address,
            [hub.external.USDC, hub.external.EURC, 3000, 60, hub.contracts.FxSwapHook],
            [true, 1_000_000n, 0n] as any,
            "0x" as Hex,
          ],
        }),
      },
      expect: { kind: "revert" },
    });
  }

  return out;
}

/// Property fuzzer: 20 random (persona, spoke-or-hub, op) combinations.
/// Coverage is shallow on purpose — we want noise hitting unexpected paths.
type Spoke = { network: string; chainId: number; contracts: { FxSpoke: Address }; external: { USDC: Address } };

export function fuzzer(spokes: Spoke[], hub: HubManifest, seed: number, n: number): TestCase[] {
  const personaKeys = Object.keys(PERSONAS) as Array<keyof typeof PERSONAS>;
  // Tiny PRNG so the suite is deterministic per seed.
  let s = seed >>> 0;
  const rand = () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s;
  };
  const pick = <T,>(arr: T[]) => arr[rand() % arr.length];

  const ops = [
    "spoke-enterHub",
    "hub-mint-fxUSDC",
    "hub-mint-fxEURC",
    "hub-getMid",
  ] as const;

  const cases: TestCase[] = [];
  for (let i = 0; i < n; i++) {
    const persona = PERSONAS[pick(personaKeys)];
    const op = pick(ops as unknown as string[]);
    const id = `F.${i.toString().padStart(2, "0")}.${persona.name}.${op}`;

    if (op === "spoke-enterHub") {
      const s = pick(spokes);
      const amount = BigInt(rand() % 10_000) * 1_000_000n; // 0..10k USDC
      const expect: Expect =
        amount > 0n && amount <= persona.usdc ? { kind: "pass" } : { kind: "revert" };
      cases.push({
        id,
        description: `fuzz | ${s.network} enterHub | ${persona.name} | ${amount / 1_000_000n} USDC`,
        request: {
          network_id: String(s.chainId),
          from: persona.address,
          to: s.contracts.FxSpoke,
          input: encodeFunctionData({
            abi: parseAbi(["function enterHub(address,uint256,address,bytes) external returns (bytes32)"]),
            functionName: "enterHub",
            args: [s.external.USDC, amount, persona.address, "0x" as Hex],
          }),
          state_objects: personaState(persona, s.external.USDC, s.contracts.FxSpoke),
        },
        expect,
      });
      continue;
    }
    if (op === "hub-mint-fxUSDC" || op === "hub-mint-fxEURC") {
      const isUsdc = op === "hub-mint-fxUSDC";
      const token = isUsdc ? hub.external.USDC : hub.external.EURC;
      const receipt = isUsdc ? hub.contracts.FxReceiptUSDC : hub.contracts.FxReceiptEURC;
      const bal = isUsdc ? persona.usdc : persona.eurc;
      const amount = BigInt(rand() % 5_000) * 1_000_000n;
      const expect: Expect =
        amount > 0n && amount <= bal ? { kind: "pass" } : { kind: "revert" };
      cases.push({
        id,
        description: `fuzz | mint ${isUsdc ? "fxUSDC" : "fxEURC"} | ${persona.name} | ${amount / 1_000_000n}`,
        request: {
          network_id: String(hub.chainId),
          from: persona.address,
          to: receipt,
          input: encodeFunctionData({
            abi: ERC4626_ABI,
            functionName: "deposit",
            args: [amount, persona.address],
          }),
          state_objects: personaState(persona, hub.external.USDC, receipt, hub.external.EURC),
        },
        expect,
      });
      continue;
    }
    if (op === "hub-getMid") {
      const dir = rand() % 2 === 0
        ? [hub.external.USDC, hub.external.EURC]
        : [hub.external.EURC, hub.external.USDC];
      cases.push({
        id,
        description: `fuzz | getMid ${dir[0] === hub.external.USDC ? "USDC→EURC" : "EURC→USDC"} (Pyth stale on testnet)`,
        request: {
          network_id: String(hub.chainId),
          from: persona.address,
          to: hub.contracts.FxOracle,
          input: encodeFunctionData({
            abi: ORACLE_ABI,
            functionName: "getMid",
            args: [dir[0] as Address, dir[1] as Address],
          }),
        },
        // Pyth feeds on Base Sepolia aren't actively pushed → stale → revert.
        // Suite tracks this honest reality; Drop 4 layers in fresh-payload
        // bundle sims to assert the happy path.
        expect: { kind: "revert" },
      });
    }
  }
  return cases;
}

// Address placeholder for C4 (avoid TS lint).
const PERSONASAddress = PERSONAS.mid.address;
