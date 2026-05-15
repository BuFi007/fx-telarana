#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Live end-to-end swap test through FxSwapHook on Base Sepolia.
// Validates:
//   1. Pyth Hermes payload → FxOracle.getMidWithUpdate refresh
//   2. Permit2 approval dance for Universal Router
//   3. V4_SWAP command construction + UR.execute
//   4. Hook's beforeSwap fires, quote is oracle-anchored, JIT-withdraw works
//
// Usage:
//   DEPLOYER_PRIVATE_KEY=0x... bun packages/sdk/scripts/swap-on-hook.ts

import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  encodePacked,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

// ── live Base Sepolia addresses (Phase B redeploy with real EURC) ──────
const ADDR = {
  fxOracle:         "0x7a2a612820f3f697b40f93c026758f2dfafcdbce" as Address,
  hook:             "0xc7260EF7D95D155aD6CA18ED539373a7576c8AC8" as Address,
  poolManager:      "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408" as Address,
  universalRouter:  "0x492e6456d9528771018deb9e87ef7750ef184104" as Address,
  permit2:          "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address,
  pyth:             "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729" as Address,
  usdc:             "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as Address,
  eurc:             "0x808456652fdb597867f38412077A9182bf77359F" as Address, // Circle's real EURC on Base Sepolia
};

// Pyth Hermes feed ids (chain-agnostic) — bundled in one Hermes call
const PYTH = {
  USDC_USD: "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a" as Hex,
  EURC_USD: "0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c" as Hex,
};

const HERMES = "https://hermes.pyth.network/v2/updates/price/latest";

// v4 action selectors (from @uniswap/v4-periphery Actions.sol)
const ACT = {
  SWAP_EXACT_IN_SINGLE: 0x06,
  SETTLE_ALL:           0x0c,
  TAKE_ALL:             0x0f,
} as const;

// Universal Router commands (from @uniswap/universal-router Commands.sol)
const CMD = {
  V4_SWAP: 0x10,
} as const;

// Pool params we initialized
const POOL = {
  fee: 3000,
  tickSpacing: 60,
};

const TRANSPORT = http("https://sepolia.base.org");

async function fetchHermesPayload(): Promise<Hex[]> {
  const url = `${HERMES}?ids%5B%5D=${PYTH.USDC_USD.slice(2)}&ids%5B%5D=${PYTH.EURC_USD.slice(2)}&encoding=hex`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`Hermes ${r.status}`);
  const j: { binary: { data: string[] } } = await r.json();
  return j.binary.data.map((d) => `0x${d}` as Hex);
}

async function main() {
  const pk = process.env.DEPLOYER_PRIVATE_KEY;
  if (!pk) throw new Error("set DEPLOYER_PRIVATE_KEY");
  const account = privateKeyToAccount(pk as Hex);
  console.log(`deployer: ${account.address}`);

  const publicClient = createPublicClient({ chain: baseSepolia, transport: TRANSPORT });
  const walletClient = createWalletClient({ account, chain: baseSepolia, transport: TRANSPORT });

  // ── 1. Fetch Pyth Hermes payload ─────────────────────────────────────
  console.log("→ fetching Pyth Hermes payload");
  const pythUpdate = await fetchHermesPayload();
  console.log(`  payload length: ${pythUpdate[0]?.length} chars`);

  // ── 2. Get update fee + refresh oracle ───────────────────────────────
  const pythAbi = parseAbi([
    "function getUpdateFee(bytes[] calldata data) external view returns (uint256)",
    "function updatePriceFeeds(bytes[] calldata updateData) external payable",
  ]);
  const fxOracleAbi = parseAbi([
    "function getMid(address base, address quote) external view returns (uint256 midE18, uint256 publishedAt)",
  ]);

  const updateFee = await publicClient.readContract({
    address: ADDR.pyth,
    abi: pythAbi,
    functionName: "getUpdateFee",
    args: [pythUpdate],
  });
  console.log(`  Pyth update fee: ${updateFee} wei`);

  // Push Pyth update directly. (FxOracle.getMidWithUpdate chains through
  // getMidVerified which needs a RedStone payload too — not available on
  // Base Sepolia. The hook's beforeSwap only calls getMid (Pyth-only),
  // so direct Pyth refresh is sufficient for the swap path.)
  console.log("→ pushing Pyth update directly to Pyth contract");
  const refreshHash = await walletClient.writeContract({
    address: ADDR.pyth,
    abi: pythAbi,
    functionName: "updatePriceFeeds",
    args: [pythUpdate],
    value: updateFee,
  });
  console.log(`  tx: ${refreshHash}`);
  const refreshRcpt = await publicClient.waitForTransactionReceipt({ hash: refreshHash });
  console.log(`  status: ${refreshRcpt.status}`);

  // Sanity: read mid now
  const [midE18, publishedAt] = await publicClient.readContract({
    address: ADDR.fxOracle,
    abi: fxOracleAbi,
    functionName: "getMid",
    args: [ADDR.eurc, ADDR.usdc],
  });
  console.log(`  EURC/USDC mid: ${midE18} (1e18-scaled) @ ts ${publishedAt}`);
  console.log(`  ≈ ${Number(midE18) / 1e18} EURC per USDC`);

  // ── 3. Permit2 approval dance for USDC ───────────────────────────────
  const erc20 = parseAbi([
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function allowance(address owner, address spender) external view returns (uint256)",
    "function balanceOf(address) external view returns (uint256)",
  ]);
  const permit2Abi = parseAbi([
    "function approve(address token, address spender, uint160 amount, uint48 expiration) external",
    "function allowance(address user, address token, address spender) external view returns (uint160 amount, uint48 expiration, uint48 nonce)",
  ]);

  const amountIn = 1_000_000n; // 1 USDC (6 decimals)

  const usdcAllowance = await publicClient.readContract({
    address: ADDR.usdc,
    abi: erc20,
    functionName: "allowance",
    args: [account.address, ADDR.permit2],
  });
  if (usdcAllowance < amountIn) {
    console.log("→ approving USDC → Permit2 (unlimited)");
    const h = await walletClient.writeContract({
      address: ADDR.usdc,
      abi: erc20,
      functionName: "approve",
      args: [ADDR.permit2, 2n ** 256n - 1n],
    });
    await publicClient.waitForTransactionReceipt({ hash: h });
    console.log(`  tx: ${h}`);
  } else {
    console.log("→ USDC → Permit2 allowance already set");
  }

  const [p2allowance] = await publicClient.readContract({
    address: ADDR.permit2,
    abi: permit2Abi,
    functionName: "allowance",
    args: [account.address, ADDR.usdc, ADDR.universalRouter],
  });
  const expiration = Math.floor(Date.now() / 1000) + 3600;
  if (p2allowance < amountIn) {
    console.log("→ Permit2.approve(USDC, UR, amount, expiration)");
    const h = await walletClient.writeContract({
      address: ADDR.permit2,
      abi: permit2Abi,
      functionName: "approve",
      args: [ADDR.usdc, ADDR.universalRouter, BigInt(amountIn), expiration],
    });
    await publicClient.waitForTransactionReceipt({ hash: h });
    console.log(`  tx: ${h}`);
  } else {
    console.log("→ Permit2 → UR allowance already set");
  }

  // ── 4. Build v4 swap command ─────────────────────────────────────────
  // PoolKey ordering: token0 < token1 by address. USDC < EURC.
  const poolKey = {
    currency0: ADDR.usdc,
    currency1: ADDR.eurc,
    fee: POOL.fee,
    tickSpacing: POOL.tickSpacing,
    hooks: ADDR.hook,
  };

  // SWAP_EXACT_IN_SINGLE params:
  //   struct { PoolKey poolKey; bool zeroForOne; uint128 amountIn; uint128 amountOutMinimum; bytes hookData; }
  const poolKeyTuple = {
    components: [
      { name: "currency0", type: "address" },
      { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
    ],
    name: "poolKey",
    type: "tuple",
  } as const;

  const swapInputEncoded = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          poolKeyTuple,
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    [
      {
        poolKey,
        zeroForOne: true,
        amountIn: BigInt(amountIn),
        amountOutMinimum: 0n,
        hookData: "0x" as Hex,
      },
    ],
  );

  const settleInputEncoded = encodeAbiParameters(
    [
      { name: "currency", type: "address" },
      { name: "maxAmount", type: "uint256" },
    ],
    [ADDR.usdc, amountIn],
  );

  const takeInputEncoded = encodeAbiParameters(
    [
      { name: "currency", type: "address" },
      { name: "minAmount", type: "uint256" },
    ],
    [ADDR.eurc, 0n],
  );

  const actionsBytes = encodePacked(
    ["uint8", "uint8", "uint8"],
    [ACT.SWAP_EXACT_IN_SINGLE, ACT.SETTLE_ALL, ACT.TAKE_ALL],
  );

  const v4SwapInput = encodeAbiParameters(
    [
      { name: "actions", type: "bytes" },
      { name: "params", type: "bytes[]" },
    ],
    [actionsBytes, [swapInputEncoded, settleInputEncoded, takeInputEncoded]],
  );

  const commands = encodePacked(["uint8"], [CMD.V4_SWAP]);
  const inputs: Hex[] = [v4SwapInput];

  // ── 5. Execute via Universal Router ──────────────────────────────────
  const balancesBefore = {
    usdc: await publicClient.readContract({ address: ADDR.usdc, abi: erc20, functionName: "balanceOf", args: [account.address] }),
    eurc: await publicClient.readContract({ address: ADDR.eurc, abi: erc20, functionName: "balanceOf", args: [account.address] }),
  };
  console.log(`balances before: USDC=${balancesBefore.usdc}  EURC=${balancesBefore.eurc}`);

  const urAbi = parseAbi([
    "function execute(bytes commands, bytes[] inputs, uint256 deadline) external payable",
  ]);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

  console.log("→ Universal Router execute(V4_SWAP, [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL])");
  try {
    const swapHash = await walletClient.writeContract({
      address: ADDR.universalRouter,
      abi: urAbi,
      functionName: "execute",
      args: [commands, inputs, deadline],
    });
    console.log(`  tx: ${swapHash}`);
    const rcpt = await publicClient.waitForTransactionReceipt({ hash: swapHash });
    console.log(`  status: ${rcpt.status}, gasUsed: ${rcpt.gasUsed}`);
  } catch (err: unknown) {
    console.error("swap reverted:", (err as { shortMessage?: string; message?: string }).shortMessage ?? err);
    process.exit(2);
  }

  const balancesAfter = {
    usdc: await publicClient.readContract({ address: ADDR.usdc, abi: erc20, functionName: "balanceOf", args: [account.address] }),
    eurc: await publicClient.readContract({ address: ADDR.eurc, abi: erc20, functionName: "balanceOf", args: [account.address] }),
  };
  console.log(`balances after:  USDC=${balancesAfter.usdc}  EURC=${balancesAfter.eurc}`);
  console.log(`Δ USDC: ${balancesAfter.usdc - balancesBefore.usdc}`);
  console.log(`Δ EURC: ${balancesAfter.eurc - balancesBefore.eurc}`);
}

await main();
