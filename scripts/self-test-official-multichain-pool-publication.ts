// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the multichain pool publication checker. It creates
// populated temporary inputs for Avalanche and Arbitrum, proves draft mode can
// pass offline preflight, proves ready mode requires live target-chain RPC
// receipt checks, and proves self-deployed PoolManagers are rejected.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { encodeAbiParameters, keccak256 } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const TEMPLATE = "deployments/uniswap-v4-official-multichain-pools.template.json";
const TEMP_DRAFT_INPUT = "deployments/.tmp-official-multichain-pools-draft.self-test.json";
const TEMP_READY_INPUT = "deployments/.tmp-official-multichain-pools-ready.self-test.json";
const TEMP_BAD_PM_INPUT = "deployments/.tmp-official-multichain-pools-bad-pm.self-test.json";
const TEMP_BAD_ROUTER_INPUT = "deployments/.tmp-official-multichain-pools-bad-router.self-test.json";
const DEFAULT_SQRT_PRICE_X96 = "79228162514264337593543950336";
const LOW_14_MASK = 0x3fffn;

const OFFICIAL_POOL_MANAGERS = {
  avalanche: "0x06380c0e0912312b5150364b9dc4542ba0dbbc85",
  "arbitrum-one": "0x360e68faccca8ca495c1b759fd9eee466db9fb32",
} as const;

const BAD_SELF_DEPLOYED_POOL_MANAGER = "0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E";

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
  for (const relativePath of [TEMP_DRAFT_INPUT, TEMP_READY_INPUT, TEMP_BAD_PM_INPUT, TEMP_BAD_ROUTER_INPUT]) {
    const absolutePath = join(ROOT, relativePath);
    if (existsSync(absolutePath)) rmSync(absolutePath);
  }
}

function hookAddressFor(index: number, expectedLow14Bits: number): string {
  const value = (BigInt(index + 1) << 16n) | BigInt(expectedLow14Bits);
  if ((value & LOW_14_MASK) !== BigInt(expectedLow14Bits)) {
    throw new Error(`generated hook address does not match low-14 bits ${expectedLow14Bits}`);
  }

  return `0x${value.toString(16).padStart(40, "0")}`;
}

function bytes32For(label: string): string {
  return keccak256(encodeAbiParameters([{ type: "string" }], [label]));
}

function poolIdFromKey(currency0: string, currency1: string, fee: number, tickSpacing: number, hooks: string): string {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [currency0 as `0x${string}`, currency1 as `0x${string}`, fee, tickSpacing, hooks as `0x${string}`],
  ));
}

function collectTemplates(manifest: AnyRecord): AnyRecord[] {
  const templates: AnyRecord[] = [];
  for (const family of manifest.hookFamilies ?? []) {
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

function routerQuoterStatusFor(
  network: keyof typeof OFFICIAL_POOL_MANAGERS,
  template: AnyRecord,
  poolManager: string,
): AnyRecord {
  if (template.family === "FxHedgeHook") {
    return {
      exactInput: "fixture-passed",
      officialV4QuoterExactInputDiagnostic: {
        status: "passed",
        command: "fixture: quoteExactInputSingle",
        quoter: network === "avalanche"
          ? "0xbe40675bb704506a3c2ccfb762dcfd1e979845c2"
          : "0x3972c00f7ed4885e145823eb7c655375d275a1c5",
        poolManager,
        hookData: "0x",
        note: "Fixture only; production records must carry the real target-chain Quoter result.",
      },
    };
  }

  if (template.family === "FxSwapHook") {
    return {
      exactInput: "supported-via-direct-quote-and-protocol-router",
      customRouteCaveat: "Fixture custom-route caveat for PMM-aware exact-input settlement.",
      note: "Fixture only; production records must carry the real route result or caveat.",
    };
  }

  return {
    customRouteCaveat: "Fixture custom-route caveat for hookData or attestation-required routing.",
    hookData: "Gateway route or trusted-router context required",
    note: "Fixture only; production records must carry the real route result or caveat.",
  };
}

function routerExecutionFor(
  network: keyof typeof OFFICIAL_POOL_MANAGERS,
  template: AnyRecord,
  poolManager: string,
): AnyRecord {
  if (template.family === "FxHedgeHook") {
    return {
      universalRouterExecution: {
        status: "passed",
        command: "fixture: Universal Router V4_SWAP exact-input execution",
        universalRouter: network === "avalanche"
          ? "0x94b75331ae8d42c1b61065089b7d48fe14aa73b7"
          : "0xa51afafe0263b40edaef0df8781ea9aa03e381a3",
        permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
        poolManager,
        planner: "fixture V4Planner exact-input single-hop",
        hookData: "0x",
        note: "Fixture only; production records must carry the real target-chain Universal Router result.",
      },
    };
  }

  if (template.family === "FxSwapHook") {
    return {
      customRouteCaveat: "Fixture custom-route caveat for PMM-aware protocol router execution.",
    };
  }

  return {
    customRouteCaveat: "Fixture custom-route caveat for hookData or attestation-required execution.",
  };
}

function officialPoolFromTemplate(
  network: keyof typeof OFFICIAL_POOL_MANAGERS,
  template: AnyRecord,
  index: number,
  poolManager = OFFICIAL_POOL_MANAGERS[network],
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
    poolManager,
    hookAddress,
    poolId,
    poolKey,
    initializeTx: bytes32For(`${network}:${template.family}:${template.symbol}:initialize`),
    firstLiquidityTx: bytes32For(`${network}:${template.family}:${template.symbol}:first-liquidity`),
    routerActiveClaim: true,
    routerQuoterStatus: routerQuoterStatusFor(network, template, poolManager),
    routerExecution: routerExecutionFor(network, template, poolManager),
    sqrtPriceX96,
    liquidity,
    stateViewVerification: {
      status: "verified",
      sqrtPriceX96,
      liquidity,
      slot0: {
        sqrtPriceX96,
        tick,
      },
    },
    subgraphVerification: {
      status: "verified",
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
    receiptVerification: {
      initializeTxVerified: true,
      firstLiquidityTxVerified: true,
    },
  };
}

function populatedTarget(
  templateTarget: AnyRecord,
  status: "draft" | "ready",
  officialPools: AnyRecord[],
  officialPoolManager = templateTarget.officialPoolManager,
): AnyRecord {
  return {
    ...templateTarget,
    status,
    officialPoolManager,
    officialPools,
  };
}

function buildPoolPublication(
  status: "draft" | "ready",
  officialPoolsByNetwork: Record<keyof typeof OFFICIAL_POOL_MANAGERS, AnyRecord[]>,
): AnyRecord {
  const template = readJson(TEMPLATE);
  return {
    ...template,
    status: status === "ready" ? "pending-pool-publication-evidence" : template.status,
    targets: (template.targets ?? []).map((target: AnyRecord) => {
      if (target.network === "avalanche") {
        return populatedTarget(target, status, officialPoolsByNetwork.avalanche);
      }
      if (target.network === "arbitrum-one") {
        return populatedTarget(target, status, officialPoolsByNetwork["arbitrum-one"]);
      }
      return target;
    }),
  };
}

function buildBadPoolManagerPublication(officialPools: AnyRecord[]): AnyRecord {
  const template = readJson(TEMPLATE);
  return {
    ...template,
    targets: (template.targets ?? []).map((target: AnyRecord) => {
      if (target.network !== "avalanche") return target;
      return populatedTarget(target, "draft", officialPools, BAD_SELF_DEPLOYED_POOL_MANAGER);
    }),
  };
}

function withBadRouterEvidence(officialPools: AnyRecord[]): AnyRecord[] {
  return officialPools.map((pool, index) => index === 0
    ? {
      ...pool,
      routerQuoterStatus: {
        note: "Fixture intentionally incomplete.",
      },
      routerExecution: {
        note: "Fixture intentionally incomplete.",
      },
    }
    : pool);
}

function runPoolPublicationCheck(inputPath: string): { status: number; stdout: string; stderr: string } {
  const env = {
    ...process.env,
    OFFICIAL_MULTICHAIN_POOL_PUBLICATION_INPUT: inputPath,
  };
  delete env.AVALANCHE_RPC_URL;
  delete env.ARBITRUM_RPC_URL;

  const result = spawnSync("bun", ["scripts/check-official-multichain-pool-publication.ts"], {
    cwd: ROOT,
    env,
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
  console.log("Official multichain pool publication checker self-test");
  console.log("mode read-only/no-broadcast; temporary fixtures are cleaned up");
  console.log("");

  cleanup();

  try {
    const manifest = readJson(READINESS_MANIFEST);
    const templates = collectTemplates(manifest);
    const avalanchePools = templates.map((template, index) => officialPoolFromTemplate("avalanche", template, index));
    const arbitrumPools = templates.map((template, index) => officialPoolFromTemplate("arbitrum-one", template, index));
    const badAvalanchePools = templates.map((template, index) =>
      officialPoolFromTemplate("avalanche", template, index, BAD_SELF_DEPLOYED_POOL_MANAGER)
    );

    writeJson(TEMP_DRAFT_INPUT, buildPoolPublication("draft", {
      avalanche: avalanchePools,
      "arbitrum-one": arbitrumPools,
    }));
    writeJson(TEMP_READY_INPUT, buildPoolPublication("ready", {
      avalanche: avalanchePools,
      "arbitrum-one": arbitrumPools,
    }));
    writeJson(TEMP_BAD_PM_INPUT, buildBadPoolManagerPublication(badAvalanchePools));
    writeJson(TEMP_BAD_ROUTER_INPUT, buildPoolPublication("draft", {
      avalanche: withBadRouterEvidence(avalanchePools),
      "arbitrum-one": arbitrumPools,
    }));

    expect(templates.length === 11, `generated ${templates.length} source pool templates`);
    expect(avalanchePools.length === 11, `generated ${avalanchePools.length} Avalanche official pool fixture records`);
    expect(arbitrumPools.length === 11, `generated ${arbitrumPools.length} Arbitrum official pool fixture records`);

    const draft = runPoolPublicationCheck(TEMP_DRAFT_INPUT);
    expect(draft.status === 0, "draft populated Avalanche/Arbitrum fixture passes offline preflight", draft.stdout || draft.stderr);
    expect(
      /summary PASS=\d+ WARN=\d+ FAIL=0/.test(draft.stdout),
      "draft populated fixture has FAIL=0",
      draft.stdout,
    );
    expect(
      draft.stdout.includes("populated pool publication is draft-only and not a readiness claim"),
      "draft populated fixture is explicitly not a readiness claim",
      draft.stdout,
    );
    expect(
      draft.stdout.includes("avalanche official pool count matches source template count")
        && draft.stdout.includes("arbitrum-one official pool count matches source template count"),
      "draft populated fixture validates per-target pool counts",
      draft.stdout,
    );

    const ready = runPoolPublicationCheck(TEMP_READY_INPUT);
    expect(ready.status !== 0, "ready populated fixture fails without target-chain RPC envs", ready.stdout || ready.stderr);
    expect(
      ready.stdout.includes("avalanche ready mode requires AVALANCHE_RPC_URL")
        && ready.stdout.includes("arbitrum-one ready mode requires ARBITRUM_RPC_URL"),
      "ready populated fixture requires live Avalanche and Arbitrum RPC receipt verification",
      ready.stdout,
    );
    expect(
      /summary PASS=\d+ WARN=2 FAIL=2/.test(ready.stdout),
      "ready populated fixture has exactly two expected RPC failures",
      ready.stdout,
    );

    const bad = runPoolPublicationCheck(TEMP_BAD_PM_INPUT);
    expect(bad.status !== 0, "self-deployed PoolManager fixture fails", bad.stdout || bad.stderr);
    expect(
      bad.stdout.includes("official PoolManager must match official deployment manifest")
        && bad.stdout.includes("reuses self-deployed/rehearsal"),
      "self-deployed PoolManager fixture fails for the explicit reuse reasons",
      bad.stdout,
    );

    const badRouter = runPoolPublicationCheck(TEMP_BAD_ROUTER_INPUT);
    expect(badRouter.status !== 0, "missing router/quoter evidence fixture fails", badRouter.stdout || badRouter.stderr);
    expect(
      badRouter.stdout.includes("router/quoter evidence must include exact-input proof or a custom-route caveat"),
      "missing router/quoter fixture fails for the explicit evidence reason",
      badRouter.stdout,
    );
    expect(
      badRouter.stdout.includes("router execution must include Universal Router proof or a custom-route caveat"),
      "missing router execution fixture fails for the explicit evidence reason",
      badRouter.stdout,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
