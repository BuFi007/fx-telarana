// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the standalone multichain StateView and subgraph
// readiness gates. It creates temporary populated Avalanche/Arbitrum fixtures
// and proves draft indexed-state evidence is validated offline.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { encodeAbiParameters, keccak256 } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const TEMPLATE = "deployments/uniswap-v4-official-multichain-pools.template.json";
const TEMP_DRAFT_INPUT = "deployments/.tmp-official-multichain-indexing-draft.self-test.json";
const TEMP_BAD_STATEVIEW_INPUT = "deployments/.tmp-official-multichain-indexing-bad-stateview.self-test.json";
const TEMP_BAD_SUBGRAPH_INPUT = "deployments/.tmp-official-multichain-indexing-bad-subgraph.self-test.json";
const DEFAULT_SQRT_PRICE_X96 = "79228162514264337593543950336";
const LOW_14_MASK = 0x3fffn;
const WRONG_HOOK_ADDRESS = "0x0000000000000000000000000000000000000bad";

const counts: Record<Severity, number> = { PASS: 0, FAIL: 0 };

function record(severity: Severity, message: string): void {
  counts[severity] += 1;
  console.log(`${severity.padEnd(4)} ${message}`);
}

function pass(message: string): void {
  record("PASS", message);
}

function fail(message: string): void {
  record("FAIL", message);
}

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function writeJson(relativePath: string, value: AnyRecord): void {
  writeFileSync(join(ROOT, relativePath), `${JSON.stringify(value, null, 2)}\n`);
}

function cleanup(): void {
  for (const relativePath of [
    TEMP_DRAFT_INPUT,
    TEMP_BAD_STATEVIEW_INPUT,
    TEMP_BAD_SUBGRAPH_INPUT,
  ]) {
    const absolutePath = join(ROOT, relativePath);
    if (existsSync(absolutePath)) rmSync(absolutePath);
  }
}

function bytes32For(label: string): string {
  return keccak256(encodeAbiParameters([{ type: "string" }], [label]));
}

function hookAddressFor(index: number, expectedLow14Bits: number): string {
  const value = (BigInt(index + 1) << 16n) | BigInt(expectedLow14Bits);
  if ((value & LOW_14_MASK) !== BigInt(expectedLow14Bits)) {
    throw new Error(`generated hook address does not match low-14 bits ${expectedLow14Bits}`);
  }

  return `0x${value.toString(16).padStart(40, "0")}`;
}

function poolIdFromKey(currency0: string, currency1: string, fee: number, tickSpacing: number, hooks: string): string {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [currency0 as `0x${string}`, currency1 as `0x${string}`, fee, tickSpacing, hooks as `0x${string}`],
  ));
}

function targetByNetwork(multichain: AnyRecord, network: "avalanche" | "arbitrum-one"): AnyRecord {
  return (multichain.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function collectTemplates(readiness: AnyRecord): AnyRecord[] {
  const templates: AnyRecord[] = [];
  for (const family of readiness.hookFamilies ?? []) {
    if (family.deployed === false) continue;
    for (const pool of family.pools ?? []) {
      const hooks = pool.hookAddress ?? family.hookAddress;
      templates.push({
        family: family.name,
        symbol: pool.symbol,
        expectedHookBits: Number(family.permissionFlagsLow14Bits),
        sourcePoolKey: {
          currency0: pool.currency0,
          currency1: pool.currency1,
          fee: Number(pool.fee),
          tickSpacing: Number(pool.tickSpacing),
          hooks,
        },
        sourceSqrtPriceX96: pool.sqrtPriceX96,
      });
    }
  }

  return templates;
}

function officialPoolFromTemplate(
  network: "avalanche" | "arbitrum-one",
  template: AnyRecord,
  target: AnyRecord,
  index: number,
): AnyRecord {
  const hookAddress = hookAddressFor(index, Number(template.expectedHookBits));
  const sourceKey = template.sourcePoolKey ?? {};
  const poolKey = {
    currency0: sourceKey.currency0,
    currency1: sourceKey.currency1,
    fee: Number(sourceKey.fee),
    tickSpacing: Number(sourceKey.tickSpacing),
    hooks: hookAddress,
  };
  const poolId = poolIdFromKey(
    poolKey.currency0,
    poolKey.currency1,
    poolKey.fee,
    poolKey.tickSpacing,
    poolKey.hooks,
  );
  const sqrtPriceX96 = template.sourceSqrtPriceX96 ?? DEFAULT_SQRT_PRICE_X96;
  const liquidity = "1000000000000";
  const tick = "0";

  return {
    family: template.family,
    symbol: template.symbol,
    poolManager: target.contracts.PoolManager,
    hookAddress,
    poolId,
    poolKey,
    initializeTx: bytes32For(`${network}:${template.family}:${template.symbol}:initialize`),
    firstLiquidityTx: bytes32For(`${network}:${template.family}:${template.symbol}:first-liquidity`),
    routerActiveClaim: true,
    sqrtPriceX96,
    sqrtPrice: sqrtPriceX96,
    tick,
    liquidity,
    stateViewVerification: {
      status: "fixture-verified",
      sqrtPriceX96,
      liquidity,
      slot0: {
        sqrtPriceX96,
        tick,
      },
    },
    subgraphVerification: {
      status: "fixture-verified",
      id: poolId,
      hooks: hookAddress,
      token0: { id: poolKey.currency0 },
      token1: { id: poolKey.currency1 },
      feeTier: String(poolKey.fee),
      tickSpacing: String(poolKey.tickSpacing),
      sqrtPrice: sqrtPriceX96,
      tick,
      liquidity,
    },
  };
}

function populatedTarget(templateTarget: AnyRecord, officialPools: AnyRecord[]): AnyRecord {
  return {
    ...templateTarget,
    status: "draft",
    officialPoolManager: templateTarget.officialPoolManager,
    officialPools,
  };
}

function buildPoolPublication(poolsByNetwork: Record<"avalanche" | "arbitrum-one", AnyRecord[]>): AnyRecord {
  const template = readJson(TEMPLATE);
  return {
    ...template,
    targets: (template.targets ?? []).map((target: AnyRecord) => {
      if (target.network === "avalanche") return populatedTarget(target, poolsByNetwork.avalanche);
      if (target.network === "arbitrum-one") return populatedTarget(target, poolsByNetwork["arbitrum-one"]);
      return target;
    }),
  };
}

function withBadStateViewEvidence(pools: AnyRecord[]): AnyRecord[] {
  return pools.map((pool, index) => index === 0
    ? {
      ...pool,
      liquidity: "0",
      stateViewVerification: {
        ...pool.stateViewVerification,
        liquidity: "0",
      },
    }
    : pool);
}

function withBadSubgraphEvidence(pools: AnyRecord[]): AnyRecord[] {
  return pools.map((pool, index) => index === 0
    ? {
      ...pool,
      subgraphVerification: {
        ...pool.subgraphVerification,
        hooks: WRONG_HOOK_ADDRESS,
        liquidity: "0",
      },
    }
    : pool);
}

function runGate(script: string, inputPath: string): { status: number; stdout: string; stderr: string } {
  const result = spawnSync("bun", [script], {
    cwd: ROOT,
    env: {
      ...process.env,
      OFFICIAL_MULTICHAIN_POOL_PUBLICATION_INPUT: inputPath,
      UNISWAP_V4_SUBGRAPH_URL: "",
    },
    encoding: "utf8",
  });

  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function expect(condition: boolean, message: string, details?: string): void {
  if (condition) {
    pass(message);
    return;
  }

  fail(message);
  if (details) console.log(details.trimEnd());
}

function main(): void {
  console.log("Official multichain indexed-state readiness checker self-test");
  console.log("mode read-only/no-broadcast; temporary fixtures are cleaned up");
  console.log("");

  cleanup();

  try {
    const readiness = readJson(READINESS_MANIFEST);
    const multichain = readJson(MULTICHAIN_MANIFEST);
    const avalancheTarget = targetByNetwork(multichain, "avalanche");
    const arbitrumTarget = targetByNetwork(multichain, "arbitrum-one");
    const templates = collectTemplates(readiness);
    const avalanchePools = templates.map((template, index) =>
      officialPoolFromTemplate("avalanche", template, avalancheTarget, index)
    );
    const arbitrumPools = templates.map((template, index) =>
      officialPoolFromTemplate("arbitrum-one", template, arbitrumTarget, index)
    );

    writeJson(TEMP_DRAFT_INPUT, buildPoolPublication({
      avalanche: avalanchePools,
      "arbitrum-one": arbitrumPools,
    }));
    writeJson(TEMP_BAD_STATEVIEW_INPUT, buildPoolPublication({
      avalanche: withBadStateViewEvidence(avalanchePools),
      "arbitrum-one": arbitrumPools,
    }));
    writeJson(TEMP_BAD_SUBGRAPH_INPUT, buildPoolPublication({
      avalanche: withBadSubgraphEvidence(avalanchePools),
      "arbitrum-one": arbitrumPools,
    }));

    expect(templates.length === 11, `generated ${templates.length} source pool templates`);
    expect(avalanchePools.length === 11, `generated ${avalanchePools.length} Avalanche indexed-state fixture records`);
    expect(arbitrumPools.length === 11, `generated ${arbitrumPools.length} Arbitrum indexed-state fixture records`);

    const draftStateView = runGate("scripts/check-official-multichain-stateview-readiness.ts", TEMP_DRAFT_INPUT);
    expect(draftStateView.status === 0, "draft populated StateView fixture passes offline preflight", draftStateView.stdout || draftStateView.stderr);
    expect(draftStateView.stdout.includes("StateView publication is draft-only and not a readiness claim"), "draft StateView fixture is explicitly not a readiness claim", draftStateView.stdout);
    expect(/summary PASS=\d+ WARN=\d+ FAIL=0/.test(draftStateView.stdout), "draft StateView fixture has FAIL=0", draftStateView.stdout);

    const draftSubgraph = runGate("scripts/check-official-multichain-subgraph-readiness.ts", TEMP_DRAFT_INPUT);
    expect(draftSubgraph.status === 0, "draft populated subgraph fixture passes offline preflight", draftSubgraph.stdout || draftSubgraph.stderr);
    expect(draftSubgraph.stdout.includes("subgraph publication is draft-only and not a readiness claim"), "draft subgraph fixture is explicitly not a readiness claim", draftSubgraph.stdout);
    expect(/summary PASS=\d+ WARN=\d+ FAIL=0/.test(draftSubgraph.stdout), "draft subgraph fixture has FAIL=0", draftSubgraph.stdout);

    const badStateView = runGate("scripts/check-official-multichain-stateview-readiness.ts", TEMP_BAD_STATEVIEW_INPUT);
    expect(badStateView.status !== 0, "bad StateView liquidity fixture fails", badStateView.stdout || badStateView.stderr);
    expect(
      badStateView.stdout.includes("StateView liquidity evidence must be nonzero"),
      "bad StateView fixture fails for the explicit liquidity reason",
      badStateView.stdout,
    );

    const badSubgraph = runGate("scripts/check-official-multichain-subgraph-readiness.ts", TEMP_BAD_SUBGRAPH_INPUT);
    expect(badSubgraph.status !== 0, "bad subgraph hooks/liquidity fixture fails", badSubgraph.stdout || badSubgraph.stderr);
    expect(
      badSubgraph.stdout.includes("subgraph hooks")
        && badSubgraph.stdout.includes("do not match"),
      "bad subgraph fixture fails for the explicit hooks reason",
      badSubgraph.stdout,
    );
    expect(
      badSubgraph.stdout.includes("subgraph liquidity is not nonzero"),
      "bad subgraph fixture fails for the explicit liquidity reason",
      badSubgraph.stdout,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
