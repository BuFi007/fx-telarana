// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the standalone multichain Quoter and Universal
// Router readiness gates. It creates temporary populated Avalanche/Arbitrum
// fixtures and proves ready-mode route evidence must use official v4 contracts.

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
const TEMP_DRAFT_INPUT = "deployments/.tmp-official-multichain-routes-draft.self-test.json";
const TEMP_READY_INPUT = "deployments/.tmp-official-multichain-routes-ready.self-test.json";
const TEMP_BAD_EVIDENCE_INPUT = "deployments/.tmp-official-multichain-routes-bad-evidence.self-test.json";
const TEMP_BAD_IDENTITY_INPUT = "deployments/.tmp-official-multichain-routes-bad-identity.self-test.json";
const DEFAULT_SQRT_PRICE_X96 = "79228162514264337593543950336";
const LOW_14_MASK = 0x3fffn;
const WRONG_OFFICIAL_CONTRACT = "0x0000000000000000000000000000000000000bAd";

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
    TEMP_READY_INPUT,
    TEMP_BAD_EVIDENCE_INPUT,
    TEMP_BAD_IDENTITY_INPUT,
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

function routerQuoterStatusFor(network: "avalanche" | "arbitrum-one", template: AnyRecord, target: AnyRecord, pool: AnyRecord): AnyRecord {
  if (template.family === "FxHedgeHook") {
    return {
      officialV4QuoterExactInputDiagnostic: {
        status: "passed",
        command: "fixture: V4Quoter.quoteExactInputSingle",
        quoter: target.contracts.Quoter,
        poolManager: target.contracts.PoolManager,
        poolId: pool.poolId,
        hookData: "0x",
        note: `Fixture for ${network}; production records must carry the real target-chain Quoter result.`,
      },
    };
  }

  if (template.family === "FxSwapHook") {
    return {
      customRouteCaveat: "Fixture custom-route caveat for PMM-aware direct quote and protocol-router settlement.",
      hookData: "Custom settlement route required; generic empty-hookData V4Quoter is not claimed.",
    };
  }

  return {
    customRouteCaveat: "Fixture custom-route caveat for Gateway attestation or trusted-router hookData.",
    hookData: "Gateway route or trusted-router context required.",
  };
}

function routerExecutionFor(network: "avalanche" | "arbitrum-one", template: AnyRecord, target: AnyRecord, pool: AnyRecord): AnyRecord {
  if (template.family === "FxHedgeHook") {
    return {
      universalRouterExecution: {
        status: "passed",
        command: "fixture: Universal Router V4_SWAP exact-input execution",
        universalRouter: target.contracts.UniversalRouter,
        permit2: target.contracts.Permit2,
        poolManager: target.contracts.PoolManager,
        poolId: pool.poolId,
        planner: "fixture V4Planner exact-input single-hop",
        hookData: "0x",
        note: `Fixture for ${network}; production records must carry the real target-chain Universal Router result.`,
      },
    };
  }

  if (template.family === "FxSwapHook") {
    return {
      customRouteCaveat: "Fixture custom-route caveat for PMM-aware protocol-router execution.",
    };
  }

  return {
    customRouteCaveat: "Fixture custom-route caveat for Gateway attestation or trusted-router hookData.",
  };
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
  const pool: AnyRecord = {
    family: template.family,
    symbol: template.symbol,
    poolManager: target.contracts.PoolManager,
    hookAddress,
    poolId,
    poolKey,
    quoteExactInput: null,
    initializeTx: bytes32For(`${network}:${template.family}:${template.symbol}:initialize`),
    firstLiquidityTx: bytes32For(`${network}:${template.family}:${template.symbol}:first-liquidity`),
    routerActiveClaim: true,
    sqrtPriceX96: template.sourceSqrtPriceX96 ?? DEFAULT_SQRT_PRICE_X96,
    liquidity: "1000000000000",
  };

  pool.routerQuoterStatus = routerQuoterStatusFor(network, template, target, pool);
  pool.routerExecution = routerExecutionFor(network, template, target, pool);
  return pool;
}

function populatedTarget(templateTarget: AnyRecord, status: "draft" | "ready", officialPools: AnyRecord[]): AnyRecord {
  return {
    ...templateTarget,
    status,
    officialPoolManager: templateTarget.officialPoolManager,
    officialPools,
  };
}

function buildPoolPublication(status: "draft" | "ready", poolsByNetwork: Record<"avalanche" | "arbitrum-one", AnyRecord[]>): AnyRecord {
  const template = readJson(TEMPLATE);
  return {
    ...template,
    status: status === "ready" ? "pending-route-evidence-fixture" : template.status,
    targets: (template.targets ?? []).map((target: AnyRecord) => {
      if (target.network === "avalanche") return populatedTarget(target, status, poolsByNetwork.avalanche);
      if (target.network === "arbitrum-one") return populatedTarget(target, status, poolsByNetwork["arbitrum-one"]);
      return target;
    }),
  };
}

function withMissingHedgeRouteEvidence(pools: AnyRecord[]): AnyRecord[] {
  return pools.map((pool, index) => index === 0
    ? {
      ...pool,
      routerQuoterStatus: {
        note: "Fixture intentionally missing exact-input Quoter evidence.",
      },
      routerExecution: {
        note: "Fixture intentionally missing Universal Router execution evidence.",
      },
    }
    : pool);
}

function withWrongOfficialRouteIdentity(pools: AnyRecord[]): AnyRecord[] {
  return pools.map((pool, index) => index === 0
    ? {
      ...pool,
      routerQuoterStatus: {
        officialV4QuoterExactInputDiagnostic: {
          ...pool.routerQuoterStatus.officialV4QuoterExactInputDiagnostic,
          quoter: WRONG_OFFICIAL_CONTRACT,
        },
      },
      routerExecution: {
        universalRouterExecution: {
          ...pool.routerExecution.universalRouterExecution,
          universalRouter: WRONG_OFFICIAL_CONTRACT,
        },
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
  console.log("Official multichain route readiness checker self-test");
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

    writeJson(TEMP_DRAFT_INPUT, buildPoolPublication("draft", {
      avalanche: avalanchePools,
      "arbitrum-one": arbitrumPools,
    }));
    writeJson(TEMP_READY_INPUT, buildPoolPublication("ready", {
      avalanche: avalanchePools,
      "arbitrum-one": arbitrumPools,
    }));
    writeJson(TEMP_BAD_EVIDENCE_INPUT, buildPoolPublication("ready", {
      avalanche: withMissingHedgeRouteEvidence(avalanchePools),
      "arbitrum-one": arbitrumPools,
    }));
    writeJson(TEMP_BAD_IDENTITY_INPUT, buildPoolPublication("ready", {
      avalanche: withWrongOfficialRouteIdentity(avalanchePools),
      "arbitrum-one": arbitrumPools,
    }));

    expect(templates.length === 11, `generated ${templates.length} source pool templates`);
    expect(avalanchePools.length === 11, `generated ${avalanchePools.length} Avalanche route fixture records`);
    expect(arbitrumPools.length === 11, `generated ${arbitrumPools.length} Arbitrum route fixture records`);

    const draftQuoter = runGate("scripts/check-official-multichain-quoter-readiness.ts", TEMP_DRAFT_INPUT);
    expect(draftQuoter.status === 0, "draft populated Quoter fixture passes offline preflight", draftQuoter.stdout || draftQuoter.stderr);
    expect(draftQuoter.stdout.includes("Quoter publication is draft-only and not a readiness claim"), "draft Quoter fixture is explicitly not a readiness claim", draftQuoter.stdout);
    expect(/summary PASS=\d+ WARN=\d+ FAIL=0/.test(draftQuoter.stdout), "draft Quoter fixture has FAIL=0", draftQuoter.stdout);

    const draftRouter = runGate("scripts/check-official-multichain-router-readiness.ts", TEMP_DRAFT_INPUT);
    expect(draftRouter.status === 0, "draft populated router fixture passes offline preflight", draftRouter.stdout || draftRouter.stderr);
    expect(draftRouter.stdout.includes("router execution publication is draft-only and not a readiness claim"), "draft router fixture is explicitly not a readiness claim", draftRouter.stdout);
    expect(/summary PASS=\d+ WARN=\d+ FAIL=0/.test(draftRouter.stdout), "draft router fixture has FAIL=0", draftRouter.stdout);

    const readyQuoter = runGate("scripts/check-official-multichain-quoter-readiness.ts", TEMP_READY_INPUT);
    expect(readyQuoter.status === 0, "ready Quoter fixture passes with official exact-input evidence", readyQuoter.stdout || readyQuoter.stderr);
    expect(readyQuoter.stdout.includes("ready FxHedgeHook exact-input Quoter evidence is recorded"), "ready Quoter fixture verifies FxHedgeHook exact-input evidence", readyQuoter.stdout);

    const readyRouter = runGate("scripts/check-official-multichain-router-readiness.ts", TEMP_READY_INPUT);
    expect(readyRouter.status === 0, "ready router fixture passes with official Universal Router evidence", readyRouter.stdout || readyRouter.stderr);
    expect(readyRouter.stdout.includes("ready FxHedgeHook router execution evidence is recorded"), "ready router fixture verifies FxHedgeHook Universal Router evidence", readyRouter.stdout);

    const badEvidenceQuoter = runGate("scripts/check-official-multichain-quoter-readiness.ts", TEMP_BAD_EVIDENCE_INPUT);
    expect(badEvidenceQuoter.status !== 0, "missing ready-mode Quoter evidence fixture fails", badEvidenceQuoter.stdout || badEvidenceQuoter.stderr);
    expect(
      badEvidenceQuoter.stdout.includes("ready FxHedgeHook pool requires official exact-input Quoter evidence"),
      "missing Quoter evidence fixture fails for the explicit FxHedgeHook evidence reason",
      badEvidenceQuoter.stdout,
    );

    const badEvidenceRouter = runGate("scripts/check-official-multichain-router-readiness.ts", TEMP_BAD_EVIDENCE_INPUT);
    expect(badEvidenceRouter.status !== 0, "missing ready-mode router evidence fixture fails", badEvidenceRouter.stdout || badEvidenceRouter.stderr);
    expect(
      badEvidenceRouter.stdout.includes("ready FxHedgeHook pool requires official Universal Router execution evidence"),
      "missing router evidence fixture fails for the explicit FxHedgeHook evidence reason",
      badEvidenceRouter.stdout,
    );

    const badIdentityQuoter = runGate("scripts/check-official-multichain-quoter-readiness.ts", TEMP_BAD_IDENTITY_INPUT);
    expect(badIdentityQuoter.status !== 0, "wrong official Quoter identity fixture fails", badIdentityQuoter.stdout || badIdentityQuoter.stderr);
    expect(
      badIdentityQuoter.stdout.includes("ready FxHedgeHook pool requires official exact-input Quoter evidence"),
      "wrong Quoter identity fixture fails as missing official evidence",
      badIdentityQuoter.stdout,
    );

    const badIdentityRouter = runGate("scripts/check-official-multichain-router-readiness.ts", TEMP_BAD_IDENTITY_INPUT);
    expect(badIdentityRouter.status !== 0, "wrong official router identity fixture fails", badIdentityRouter.stdout || badIdentityRouter.stderr);
    expect(
      badIdentityRouter.stdout.includes("ready FxHedgeHook pool requires official Universal Router execution evidence"),
      "wrong router identity fixture fails as missing official evidence",
      badIdentityRouter.stdout,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
