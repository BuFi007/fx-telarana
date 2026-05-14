#!/usr/bin/env bun
// Liquidation drill on live Base Sepolia.
//
// 1. Deploy TestableOracleAdapter (admin-settable IOracle.price()).
// 2. Register a new Morpho market via FxMarketRegistry using:
//      loanToken       = real USDC
//      collateralToken = v1 MockEURC (deployer already holds 2000 of them)
//      oracle          = TestableOracleAdapter (1e36 → 1 collat = 1 loan)
//      irm             = AdaptiveCurveIrm
//      lltv            = 0.86e18
// 3. Authorize FxMarketRegistry on Morpho (for borrow/withdraw).
// 4. Supply 2 USDC as the lender side.
// 5. Supply 2 MockEURC as collateral.
// 6. Borrow 1.6 USDC (80% LTV at 1e36 price — healthy under 86% LLTV).
// 7. Drop adapter price to 0.5e36 — collateral worth halves, position underwater.
// 8. Call FxLiquidator.liquidate to seize collateral.
// 9. Print before/after snapshots.

import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "../../..");

// ── live Base Sepolia addresses ────────────────────────────────────────
const ADDR = {
  registry:         "0x30f4c7bce1e0c5ca5d2ecd2ebdbf13f6273fe7fe" as Address,
  liquidator:       "0xf4556f31cace9a80aa584059c81638a5cd344dde" as Address,
  morpho:           "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb" as Address,
  adaptiveCurveIrm: "0x46415998764C29aB2a25CbeA6254146D50D22687" as Address,
  usdc:             "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as Address,
  mockEurc:         "0x8B7041d8A4bd773a537a01e1F61175da5395714c" as Address, // v1 MockEURC
};

const LLTV = 860_000_000_000_000_000n;          // 0.86e18
const INITIAL_PRICE = 10n ** 36n;               // 1 collat = 1 loan
const CRASH_PRICE   = 5n * 10n ** 35n;          // 0.5 collat = 1 loan
const TRANSPORT = http("https://sepolia.base.org");

const erc20 = parseAbi([
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address, address) external view returns (uint256)",
  "function balanceOf(address) external view returns (uint256)",
]);

const registryAbi = parseAbi([
  "function createAndRegisterMarket((address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) p) external returns (bytes32)",
  "function marketIdOf(address loanToken, address collateralToken) external view returns (bytes32)",
  "function supply(address loanToken, address collateralToken, uint256 assets, address onBehalf) external returns (uint256 sharesMinted)",
  "function supplyCollateral(address loanToken, address collateralToken, uint256 collateral, address onBehalf) external",
  "function borrow(address loanToken, address collateralToken, uint256 assets, address onBehalf, address receiver) external returns (uint256 borrowedShares)",
]);

const morphoAbi = parseAbi([
  "function setAuthorization(address authorized, bool isAuthorized) external",
  "function isAuthorized(address authorizer, address authorized) external view returns (bool)",
  "function position(bytes32 id, address user) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)",
]);

const liquidatorAbi = parseAbi([
  "function liquidate(address loanToken, address collateralToken, address borrower, uint256 seizedAssets, uint256 repaidShares, uint256 maxRepayAssets, bool useVerified, bytes[] pythUpdate) external payable returns (uint256 seized, uint256 repaid)",
]);

const adapterAbi = parseAbi([
  "function setPrice(uint256 newPrice) external",
  "function price() external view returns (uint256)",
]);

async function deployTestableOracleAdapter(walletClient: ReturnType<typeof createWalletClient>, publicClient: ReturnType<typeof createPublicClient>, deployer: Address): Promise<Address> {
  const artifactPath = resolve(REPO_ROOT, "contracts/out/TestableOracleAdapter.sol/TestableOracleAdapter.json");
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const bytecode = artifact.bytecode.object as Hex;

  // Manually concatenate bytecode + abi-encoded constructor args.
  // (Skip viem.deployContract — it requires the full ABI to find the
  // constructor; we just need the bytecode + a raw eth_sendTransaction.)
  const ctorArgs = encodeAbiParameters(
    [{ name: "owner_", type: "address" }, { name: "initialPrice", type: "uint256" }],
    [deployer, INITIAL_PRICE],
  );
  const deployData = (bytecode + ctorArgs.slice(2)) as Hex;

  const hash = await walletClient.sendTransaction({
    data: deployData,
    account: walletClient.account!,
    chain: baseSepolia,
  });
  const rcpt = await publicClient.waitForTransactionReceipt({ hash });
  if (!rcpt.contractAddress) throw new Error("adapter deploy: no contract address");
  return rcpt.contractAddress;
}

async function main() {
  const pk = process.env.DEPLOYER_PRIVATE_KEY;
  if (!pk) throw new Error("set DEPLOYER_PRIVATE_KEY");
  const account = privateKeyToAccount(pk as Hex);
  console.log(`deployer: ${account.address}`);

  const pub = createPublicClient({ chain: baseSepolia, transport: TRANSPORT });
  const wal = createWalletClient({ account, chain: baseSepolia, transport: TRANSPORT });

  const balances = async (label: string) => {
    const u = await pub.readContract({ address: ADDR.usdc, abi: erc20, functionName: "balanceOf", args: [account.address] });
    const e = await pub.readContract({ address: ADDR.mockEurc, abi: erc20, functionName: "balanceOf", args: [account.address] });
    console.log(`  [${label}] USDC=${u}  MockEURC=${e}`);
  };

  await balances("start");

  // ── 1. Locate or deploy the TestableOracleAdapter ────────────────────
  let adapter: Address;
  try {
    const params = await pub.readContract({
      address: ADDR.registry,
      abi: parseAbi(["function paramsOf(address, address) external view returns ((address, address, address, address, uint256))"]),
      functionName: "paramsOf",
      args: [ADDR.usdc, ADDR.mockEurc],
    });
    adapter = params[2];
    console.log(`→ reusing existing adapter (from prior drill run): ${adapter}`);
  } catch {
    console.log("→ deploying TestableOracleAdapter");
    adapter = await deployTestableOracleAdapter(wal, pub, account.address);
    console.log(`  adapter: ${adapter}`);
  }
  // Reset price to initial in case previous run left it crashed
  const currentPrice = await pub.readContract({ address: adapter, abi: adapterAbi, functionName: "price" });
  if (currentPrice !== INITIAL_PRICE) {
    console.log(`→ resetting adapter.price(${currentPrice}) → ${INITIAL_PRICE}`);
    const h = await wal.writeContract({ address: adapter, abi: adapterAbi, functionName: "setPrice", args: [INITIAL_PRICE] });
    await pub.waitForTransactionReceipt({ hash: h });
  }

  // ── 2. Create + register the new market (idempotent) ────────────────
  let marketId: Hex;
  try {
    marketId = await pub.readContract({
      address: ADDR.registry,
      abi: registryAbi,
      functionName: "marketIdOf",
      args: [ADDR.usdc, ADDR.mockEurc],
    });
    console.log(`→ market (USDC, MockEURC) already registered → ${marketId}`);
    console.log("  WARNING: existing market uses the previous adapter, not the freshly deployed one.");
    console.log("  This drill flow assumes the existing market's adapter responds to setPrice(uint256).");
  } catch {
    console.log("→ createAndRegisterMarket(USDC, MockEURC, adapter, AdaptiveCurve, 0.86 LLTV)");
    const createHash = await wal.writeContract({
      address: ADDR.registry,
      abi: registryAbi,
      functionName: "createAndRegisterMarket",
      args: [
        {
          loanToken: ADDR.usdc,
          collateralToken: ADDR.mockEurc,
          oracle: adapter,
          irm: ADDR.adaptiveCurveIrm,
          lltv: LLTV,
        },
      ],
    });
    const rc = await pub.waitForTransactionReceipt({ hash: createHash });
    if (rc.status !== "success") throw new Error(`createAndRegisterMarket reverted: ${createHash}`);
    // brief sleep so the next read sees the new state
    await new Promise((r) => setTimeout(r, 3000));
    marketId = await pub.readContract({
      address: ADDR.registry,
      abi: registryAbi,
      functionName: "marketIdOf",
      args: [ADDR.usdc, ADDR.mockEurc],
    });
    console.log(`  marketId: ${marketId}`);
  }

  // ── 3. Authorize registry on Morpho ──────────────────────────────────
  const isAuth = await pub.readContract({
    address: ADDR.morpho,
    abi: morphoAbi,
    functionName: "isAuthorized",
    args: [account.address, ADDR.registry],
  });
  if (!isAuth) {
    console.log("→ Morpho.setAuthorization(registry, true)");
    const h = await wal.writeContract({
      address: ADDR.morpho,
      abi: morphoAbi,
      functionName: "setAuthorization",
      args: [ADDR.registry, true],
    });
    await pub.waitForTransactionReceipt({ hash: h });
  } else {
    console.log("→ registry already authorized on Morpho");
  }

  // ── 4. Approve registry for USDC + MockEURC ──────────────────────────
  for (const [token, label] of [[ADDR.usdc, "USDC"], [ADDR.mockEurc, "MockEURC"]] as const) {
    const al = await pub.readContract({ address: token, abi: erc20, functionName: "allowance", args: [account.address, ADDR.registry] });
    if (al < 10_000_000n) {
      console.log(`→ approve registry for ${label}`);
      const h = await wal.writeContract({ address: token, abi: erc20, functionName: "approve", args: [ADDR.registry, 2n ** 256n - 1n] });
      await pub.waitForTransactionReceipt({ hash: h });
    }
  }

  // ── 5. Idempotent supply (lender side) ───────────────────────────────
  // Lender position lives at the same Morpho position; rerunning the
  // drill should skip if we already have supply shares.
  let existing = await pub.readContract({
    address: ADDR.morpho,
    abi: morphoAbi,
    functionName: "position",
    args: [marketId as Hex, account.address],
  });
  const SUPPLY_USDC = 2_000_000n;
  if (existing[0] === 0n) {
    console.log(`→ supply ${SUPPLY_USDC} USDC into new market (lender side)`);
    let h = await wal.writeContract({
      address: ADDR.registry,
      abi: registryAbi,
      functionName: "supply",
      args: [ADDR.usdc, ADDR.mockEurc, SUPPLY_USDC, account.address],
    });
    await pub.waitForTransactionReceipt({ hash: h });
  } else {
    console.log(`→ already have ${existing[0]} supply shares; skipping supply`);
  }

  // ── 6. Idempotent supplyCollateral ───────────────────────────────────
  const COLLAT_AMOUNT = 500_000n; // 0.5 MockEURC
  if (existing[2] === 0n) {
    console.log(`→ supplyCollateral ${COLLAT_AMOUNT} MockEURC`);
    let h = await wal.writeContract({
      address: ADDR.registry,
      abi: registryAbi,
      functionName: "supplyCollateral",
      args: [ADDR.usdc, ADDR.mockEurc, COLLAT_AMOUNT, account.address],
    });
    await pub.waitForTransactionReceipt({ hash: h });
  } else {
    console.log(`→ already have ${existing[2]} collateral; skipping`);
  }

  // ── 7. Idempotent borrow ─────────────────────────────────────────────
  // Refresh position
  existing = await pub.readContract({
    address: ADDR.morpho,
    abi: morphoAbi,
    functionName: "position",
    args: [marketId as Hex, account.address],
  });
  const BORROW_USDC = 300_000n; // 0.3 USDC; 60% LTV at 1e36 price (healthy < 86% LLTV)
  if (existing[1] === 0n) {
    console.log(`→ borrow ${BORROW_USDC} USDC`);
    let h = await wal.writeContract({
      address: ADDR.registry,
      abi: registryAbi,
      functionName: "borrow",
      args: [ADDR.usdc, ADDR.mockEurc, BORROW_USDC, account.address, account.address],
    });
    await pub.waitForTransactionReceipt({ hash: h });
  } else {
    console.log(`→ already have ${existing[1]} borrow shares; skipping`);
  }

  await balances("post-borrow");
  let pos = await pub.readContract({
    address: ADDR.morpho,
    abi: morphoAbi,
    functionName: "position",
    args: [marketId as Hex, account.address],
  });
  console.log(`  position: supplyShares=${pos[0]}  borrowShares=${pos[1]}  collateral=${pos[2]}`);

  // ── 8. Crash the oracle price ────────────────────────────────────────
  console.log(`→ crash adapter.setPrice(${CRASH_PRICE}) — collateral now worth half`);
  let h = await wal.writeContract({
    address: adapter,
    abi: adapterAbi,
    functionName: "setPrice",
    args: [CRASH_PRICE],
  });
  await pub.waitForTransactionReceipt({ hash: h });

  // ── 9. Approve liquidator for USDC repay ─────────────────────────────
  // Cap repay at 200_000 (0.2 USDC). The liquidator now pulls only this exact
  // amount, not the full allowance, so we can approve a larger safety buffer.
  const MAX_REPAY = 200_000n;
  console.log(`→ approve liquidator for ${MAX_REPAY} USDC repay`);
  h = await wal.writeContract({
    address: ADDR.usdc,
    abi: erc20,
    functionName: "approve",
    args: [ADDR.liquidator, MAX_REPAY],
  });
  await pub.waitForTransactionReceipt({ hash: h });

  // ── 10. Liquidate: seize 0.25 MockEURC ───────────────────────────────
  const SEIZE = 250_000n; // 0.25 MockEURC
  console.log(`→ FxLiquidator.liquidate(seizedAssets=${SEIZE} MockEURC)`);
  h = await wal.writeContract({
    address: ADDR.liquidator,
    abi: liquidatorAbi,
    functionName: "liquidate",
    args: [
      ADDR.usdc,
      ADDR.mockEurc,
      account.address,            // borrower (= us)
      SEIZE,                      // seize 0.25 MockEURC
      0n,                         // repaidShares = 0 (we specify seizedAssets)
      MAX_REPAY,                  // maxRepayAssets — cap caller pull
      false,                      // useVerified — Base Sepolia has no RedStone signers
      [] as Hex[],                // no Pyth update — adapter is TestableAdapter
    ],
  });
  const liqRcpt = await pub.waitForTransactionReceipt({ hash: h });
  console.log(`  status: ${liqRcpt.status}, gasUsed: ${liqRcpt.gasUsed}`);

  await balances("post-liquidation");
  pos = await pub.readContract({
    address: ADDR.morpho,
    abi: morphoAbi,
    functionName: "position",
    args: [marketId as Hex, account.address],
  });
  console.log(`  position: supplyShares=${pos[0]}  borrowShares=${pos[1]}  collateral=${pos[2]}`);
}

await main();
