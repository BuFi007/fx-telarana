/**
 * Drop 8 — Universal Router V4_SWAP simulation against the live FxSwapHook.
 *
 * Pattern copied from `packages/sdk/scripts/swap-on-hook.ts` (the production
 * live-swap helper). The sim bundles:
 *
 *   1. Pyth.updatePriceFeeds(hermesPayload)   pays fee, freshens FxOracle's
 *                                              underlying Pyth feeds.
 *   2. UR.execute(commands=V4_SWAP, [actions=SWAP_EXACT_IN_SINGLE +
 *                                            SETTLE_ALL + TAKE_ALL])
 *      triggers PoolManager.swap → FxSwapHook.beforeSwap → PMM quote.
 *
 * State overrides handle Permit2 + ERC-20 allowance + USDC balance so the
 * whale persona can call UR.execute with no real on-chain prep.
 *
 * NOTE: the live hub currently has minimal LP on FxSwapHook (the production
 * `swap-on-hook.ts` script only did one tiny test swap). If the hook reverts
 * on insufficient reserves, this sim asserts revert — it still exercises the
 * full UR → Permit2 → PoolManager → hook calldata path. Once meaningful LP
 * is deposited via `FxSwapHook.deposit`, flip expectations to `pass`.
 */
import {
  encodeAbiParameters,
  encodeFunctionData,
  encodePacked,
  keccak256,
  pad,
  parseAbi,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { balanceSlot, allowanceSlot, valueHex as hex32, type SimulateRequest } from "./client.js";
import { PERSONAS, personaState } from "./personas.js";
import type { TestCase } from "./matrix.js";

type HubManifest = {
  chainId: number;
  contracts: { FxSwapHook: Address };
  external: { USDC: Address; EURC: Address; Pyth: Address };
};

const PERMIT2: Address = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const UNIVERSAL_ROUTER: Address = "0x492e6456d9528771018deb9e87ef7750ef184104";
const POOL_MANAGER: Address = "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408";

// Permit2 storage: `allowance` mapping is at slot 1 (slot 0 = nonceBitmap on
// SignatureTransfer parent). PackedAllowance packs into one slot:
//   bytes [0..20)  amount   (uint160)
//   bytes [20..26) expiration (uint48)
//   bytes [26..32) nonce      (uint48)
const PERMIT2_ALLOWANCE_SLOT = 1;

function permit2AllowanceSlot(owner: Address, token: Address, spender: Address): Hex {
  // slot(owner) = keccak(owner . PERMIT2_ALLOWANCE_SLOT)
  // slot(owner, token) = keccak(token . slot(owner))
  // slot(owner, token, spender) = keccak(spender . slot(owner, token))
  const s1 = keccak256(
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [owner, BigInt(PERMIT2_ALLOWANCE_SLOT)]),
  );
  const s2 = keccak256(
    encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [token, s1]),
  );
  return keccak256(
    encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [spender, s2]),
  );
}

function packPermit2Allowance(amount: bigint, expiration: bigint, nonce: bigint): Hex {
  const packed = amount | (expiration << 160n) | (nonce << 208n);
  return pad(toHex(packed), { size: 32 });
}

const PYTH_USDC_USD = "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a";
const PYTH_EURC_USD = "0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c";

async function fetchHermes(): Promise<Hex[]> {
  const url = `https://hermes.pyth.network/api/latest_vaas?ids[]=${PYTH_USDC_USD}&ids[]=${PYTH_EURC_USD}`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`Hermes ${r.status}`);
  const vaas = (await r.json()) as string[];
  return vaas.map((b64) => `0x${Buffer.from(b64, "base64").toString("hex")}` as Hex);
}

const PYTH_ABI = parseAbi([
  "function updatePriceFeeds(bytes[] calldata updateData) external payable",
]);

const UR_ABI = parseAbi([
  "function execute(bytes commands, bytes[] inputs, uint256 deadline) external payable",
]);

// Uniswap v4 action selectors (from periphery Actions.sol)
const ACT_SWAP_EXACT_IN_SINGLE = 0x06;
const ACT_SETTLE_ALL = 0x0c;
const ACT_TAKE_ALL = 0x0f;
const CMD_V4_SWAP = 0x10;

export async function categoryH(hub: HubManifest): Promise<TestCase[]> {
  const out: TestCase[] = [];
  const whale = PERSONAS.whale;
  const pythUpdate = await fetchHermes();

  const amountIn = 1_000_000n; // 1 USDC
  // POOL key order: token0 < token1 by address. USDC < EURC on Base Sepolia.
  const poolKey = {
    currency0: hub.external.USDC,
    currency1: hub.external.EURC,
    fee: 3000,
    tickSpacing: 60,
    hooks: hub.contracts.FxSwapHook,
  };

  const swapInputEncoded = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          {
            name: "poolKey",
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ],
          },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    [{ poolKey, zeroForOne: true, amountIn, amountOutMinimum: 0n, hookData: "0x" }],
  );
  const settleInputEncoded = encodeAbiParameters(
    [
      { name: "currency", type: "address" },
      { name: "maxAmount", type: "uint256" },
    ],
    [hub.external.USDC, amountIn],
  );
  const takeInputEncoded = encodeAbiParameters(
    [
      { name: "currency", type: "address" },
      { name: "minAmount", type: "uint256" },
    ],
    [hub.external.EURC, 0n],
  );
  const actionsBytes = encodePacked(
    ["uint8", "uint8", "uint8"],
    [ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL],
  );
  const v4SwapInput = encodeAbiParameters(
    [
      { name: "actions", type: "bytes" },
      { name: "params", type: "bytes[]" },
    ],
    [actionsBytes, [swapInputEncoded, settleInputEncoded, takeInputEncoded]],
  );
  const commands = encodePacked(["uint8"], [CMD_V4_SWAP]);
  const inputs: Hex[] = [v4SwapInput];

  const farFuture = BigInt(Math.floor(Date.now() / 1000) + 365 * 24 * 3600);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

  // State for the UR.execute step:
  //   - whale USDC balance pre-loaded
  //   - whale USDC → Permit2 ERC-20 allowance = max
  //   - Permit2 internal allowance[whale][USDC][UR] = (max_uint160, far_future_exp, 0)
  //   - whale ETH for Pyth fee
  const state: Record<Address, any> = {
    [hub.external.USDC]: {
      storage: {
        [balanceSlot(whale.address, 9)]: hex32(amountIn * 100n),
        [allowanceSlot(whale.address, PERMIT2, 10)]: hex32(2n ** 256n - 1n),
      },
    },
    [PERMIT2]: {
      storage: {
        [permit2AllowanceSlot(whale.address, hub.external.USDC, UNIVERSAL_ROUTER)]:
          packPermit2Allowance(2n ** 160n - 1n, farFuture, 0n),
      },
    },
    [whale.address]: { balance: "0x8AC7230489E80000" /* 10 ETH */ },
  };

  // H1: bundled Pyth-refresh + UR.execute swap. The live FxSwapHook does
  // hold enough LP for a 1-USDC swap (the production `swap-on-hook.ts`
  // bootstrapped LP via FxSwapHook.deposit earlier in the dev cycle).
  out.push({
    id: "H.universal-router.usdc-to-eurc",
    description: "UR.execute V4_SWAP USDC→EURC via FxSwapHook (Pyth-fresh bundle, full Permit2/UR path)",
    request: {
      network_id: String(hub.chainId),
      from: whale.address,
      to: UNIVERSAL_ROUTER,
      input: encodeFunctionData({
        abi: UR_ABI,
        functionName: "execute",
        args: [commands, inputs, deadline],
      }),
      state_objects: state,
    },
    expect: { kind: "pass" },
    bundle: [
      {
        network_id: String(hub.chainId),
        from: whale.address,
        to: hub.external.Pyth,
        input: encodeFunctionData({
          abi: PYTH_ABI,
          functionName: "updatePriceFeeds",
          args: [pythUpdate],
        }),
        value: "1000000000000000",
        state_objects: { [whale.address]: { balance: "0x8AC7230489E80000" } },
      },
      {
        network_id: String(hub.chainId),
        from: whale.address,
        to: UNIVERSAL_ROUTER,
        input: encodeFunctionData({
          abi: UR_ABI,
          functionName: "execute",
          args: [commands, inputs, deadline],
        }),
        state_objects: state,
      },
    ],
  } as TestCase);

  return out;
}
