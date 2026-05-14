#!/usr/bin/env bun
// Register fx-Telarana contracts into Circle Smart Contract Platform.
//
// Usage:
//   CIRCLE_API_KEY=TEST_API_KEY:... \
//   ENTITY_SECRET=... \
//   bun packages/sdk/scripts/register-contracts.ts deployments/tenderly-base-sepolia.json
//
// What it does (per contract listed in the deployment JSON):
//   1. importContract(...) into Circle SCP, supplying the ABI from our compiled
//      forge artifacts. Idempotent: on dup, falls back to listContracts + match.
//   2. (Optional) Creates event monitors with a webhook target if WEBHOOK_URL is
//      set. Skipped otherwise.
//
// Re-run safe — Circle's idempotency key + our "find by address" fallback mean
// repeat invocations don't error out.

import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "../../..");

interface Deployment {
  network: string;
  chainId: number;
  contracts: Record<string, string>;
  marketIds?: Record<string, string>;
  external?: Record<string, string>;
}

const CHAIN_ID_TO_CIRCLE = new Map<number, string>([
  [1, "ETH"],
  [11155111, "ETH-SEPOLIA"],
  [137, "MATIC"],
  [80002, "MATIC-AMOY"],
  [8453, "BASE"],
  [84532, "BASE-SEPOLIA"],
  [42161, "ARB"],
  [421614, "ARB-SEPOLIA"],
  [10, "OP"],
  [11155420, "OP-SEPOLIA"],
  [43114, "AVAX"],
  [43113, "AVAX-FUJI"],
  [5042002, "ARC-TESTNET"],
  [130, "UNI"],
  [1301, "UNI-SEPOLIA"],
  [143, "MONAD"],
  [10143, "MONAD-TESTNET"],
]);

// Maps the slug in deployment.contracts → forge artifact directory under contracts/out/
const ARTIFACT_DIR_OF: Record<string, string> = {
  FxOracle: "FxOracle.sol",
  MorphoOracleAdapterM1: "MorphoOracleAdapter.sol",
  MorphoOracleAdapterM2: "MorphoOracleAdapter.sol",
  FxMarketRegistry: "FxMarketRegistry.sol",
  FxReceiptEURC: "FxReceipt.sol",
  FxReceiptUSDC: "FxReceipt.sol",
  FxLiquidator: "FxLiquidator.sol",
  FxHubMessageReceiver: "FxHubMessageReceiver.sol",
  FxSpoke: "FxSpoke.sol",
  MockEURC: "MockEURC.sol",
};

const ARTIFACT_FILE_OF: Record<string, string> = {
  FxOracle: "FxOracle.json",
  MorphoOracleAdapterM1: "MorphoOracleAdapter.json",
  MorphoOracleAdapterM2: "MorphoOracleAdapter.json",
  FxMarketRegistry: "FxMarketRegistry.json",
  FxReceiptEURC: "FxReceipt.json",
  FxReceiptUSDC: "FxReceipt.json",
  FxLiquidator: "FxLiquidator.json",
  FxHubMessageReceiver: "FxHubMessageReceiver.json",
  FxSpoke: "FxSpoke.json",
  MockEURC: "MockEURC.json",
};

// Events we care about: contract-slug → array of event signatures (no spaces).
const EVENTS_OF: Record<string, string[]> = {
  FxMarketRegistry: ["MarketRegistered(bytes32,address,address,address,uint256)"],
  FxHubMessageReceiver: [
    "DepositExecuted(bytes32,address,uint256)",
    "DepositStranded(bytes32,address,uint256,bytes)",
    "DepositSwept(bytes32,address,uint256)",
  ],
  FxSpoke: [
    "Entered(bytes32,address,address,uint256,bytes)",
    "Exited(bytes32,address,address,uint256)",
  ],
  FxOracle: [
    "FeedSet(address,bytes32)",
    "RedstoneFeedSet(address,bytes32)",
    "ConfigUpdated(uint256,uint256,uint256)",
    "OwnerTransferred(address,address)",
  ],
};

async function main() {
  const apiKey = process.env.CIRCLE_API_KEY;
  const entitySecret = process.env.ENTITY_SECRET;
  if (!apiKey || !entitySecret) {
    console.error("ERROR: set CIRCLE_API_KEY and ENTITY_SECRET in env first.");
    console.error("       See https://developers.circle.com/contracts for keys.");
    process.exit(1);
  }

  const deploymentPath = process.argv[2];
  if (!deploymentPath) {
    console.error("usage: bun register-contracts.ts <deployment-json-path>");
    process.exit(1);
  }
  const absPath = resolve(process.cwd(), deploymentPath);
  if (!existsSync(absPath)) {
    console.error(`deployment file not found: ${absPath}`);
    process.exit(1);
  }
  const deployment: Deployment = JSON.parse(readFileSync(absPath, "utf8"));
  const circleChain = CHAIN_ID_TO_CIRCLE.get(deployment.chainId);
  if (!circleChain) {
    console.error(`chainId ${deployment.chainId} not in Circle SCP supported list`);
    process.exit(1);
  }

  // Dynamic import keeps the heavy SDK out of the SDK's runtime peer deps.
  const { initiateSmartContractPlatformClient } = await import(
    "@circle-fin/smart-contract-platform"
  );
  const scp = initiateSmartContractPlatformClient({
    apiKey,
    entitySecret,
  });

  console.log(`network: ${deployment.network} (Circle: ${circleChain})`);
  console.log(`registering ${Object.keys(deployment.contracts).length} contracts…`);

  const webhookUrl = process.env.WEBHOOK_URL;

  for (const [slug, address] of Object.entries(deployment.contracts)) {
    const artifactDir = ARTIFACT_DIR_OF[slug];
    const artifactFile = ARTIFACT_FILE_OF[slug];
    if (!artifactDir || !artifactFile) {
      console.warn(`skip ${slug}: no artifact mapping`);
      continue;
    }
    const artifactPath = resolve(REPO_ROOT, "contracts/out", artifactDir, artifactFile);
    if (!existsSync(artifactPath)) {
      console.warn(`skip ${slug}: artifact missing at ${artifactPath}`);
      continue;
    }
    const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));

    let contractId: string | undefined;
    try {
      const res = await scp.importContract({
        idempotencyKey: randomUUID(),
        blockchain: circleChain as Parameters<typeof scp.importContract>[0]["blockchain"],
        address,
        name: slug.replace(/[^A-Za-z0-9]/g, ""),
        abi: JSON.stringify(artifact.abi),
      });
      contractId = res.data?.contract?.id;
      console.log(`✓ imported ${slug} → ${contractId}`);
    } catch (err: unknown) {
      const message = (err as { message?: string }).message ?? String(err);
      if (message.includes("175004") || message.toLowerCase().includes("duplicate")) {
        const list = await scp.listContracts({
          blockchain: circleChain as Parameters<typeof scp.listContracts>[0]["blockchain"],
        });
        const found = list.data?.contracts?.find(
          (c: { contractAddress?: string; address?: string; id: string }) =>
            (c.contractAddress ?? c.address ?? "").toLowerCase() === address.toLowerCase(),
        );
        if (!found) {
          console.error(`✗ ${slug}: duplicate but not found in listContracts`);
          continue;
        }
        contractId = found.id;
        console.log(`↻ ${slug} already imported → ${contractId}`);
      } else {
        console.error(`✗ ${slug}: ${message}`);
        continue;
      }
    }

    if (!webhookUrl) continue;
    const events = EVENTS_OF[slug];
    if (!events || events.length === 0) continue;

    for (const eventSignature of events) {
      try {
        // Circle SDK exposes event-monitor creation; the exact method name varies
        // by SDK version. We probe a few common names.
        const client = scp as unknown as Record<string, unknown>;
        const fn =
          (client.createEventMonitor as ((args: unknown) => Promise<unknown>) | undefined) ??
          (client.createWebhook as ((args: unknown) => Promise<unknown>) | undefined);
        if (!fn) {
          console.warn(
            `⚠ event-monitor create method not found in SDK — skipping ${slug}.${eventSignature}`,
          );
          break;
        }
        await fn({
          idempotencyKey: randomUUID(),
          contractId,
          eventSignature,
          webhookUrl,
        });
        console.log(`  + monitor ${slug}.${eventSignature}`);
      } catch (err: unknown) {
        const m = (err as { message?: string }).message ?? String(err);
        if (m.includes("175302") || m.toLowerCase().includes("duplicate")) {
          console.log(`  ↻ monitor ${slug}.${eventSignature} (already exists)`);
        } else {
          console.warn(`  ⚠ monitor ${slug}.${eventSignature}: ${m}`);
        }
      }
    }
  }

  console.log("done.");
}

await main();
