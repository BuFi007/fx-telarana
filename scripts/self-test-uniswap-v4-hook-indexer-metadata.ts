// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the hook indexer metadata exporter. It proves the
// exporter rejects stale or fabricated PoolKey-derived identity data.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const TEMP_GOOD = "deployments/.tmp-hook-metadata-good.self-test.json";
const TEMP_BAD_POOL_ID = "deployments/.tmp-hook-metadata-bad-pool-id.self-test.json";
const TEMP_BAD_PERMISSION_BITS = "deployments/.tmp-hook-metadata-bad-permission-bits.self-test.json";
const EXPORTER = "bun scripts/export-uniswap-v4-hook-indexer-metadata.ts";
const MANIFEST_ENV = "UNISWAP_HOOK_METADATA_MANIFEST";

const counts = { PASS: 0, FAIL: 0 };

function pass(message: string): void {
  counts.PASS += 1;
  console.log(`PASS ${message}`);
}

function fail(message: string, detail?: string): never {
  counts.FAIL += 1;
  console.error(`FAIL ${message}`);
  if (detail) console.error(detail);
  throw new Error(message);
}

function expect(condition: boolean, message: string, detail?: string): void {
  if (condition) pass(message);
  else fail(message, detail);
}

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function writeJson(relativePath: string, value: AnyRecord): void {
  writeFileSync(join(ROOT, relativePath), `${JSON.stringify(value, null, 2)}\n`);
}

function cleanup(): void {
  for (const relativePath of [TEMP_GOOD, TEMP_BAD_POOL_ID, TEMP_BAD_PERMISSION_BITS]) {
    const absolutePath = join(ROOT, relativePath);
    if (existsSync(absolutePath)) rmSync(absolutePath);
  }
}

function runExporter(relativeManifestPath: string): { status: number; stdout: string; stderr: string } {
  const proc = Bun.spawnSync({
    cmd: ["bash", "-lc", EXPORTER],
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      [MANIFEST_ENV]: relativeManifestPath,
    },
  });

  return {
    status: proc.exitCode ?? 1,
    stdout: proc.stdout.toString(),
    stderr: proc.stderr.toString(),
  };
}

function firstDeployedFamilyWithPools(manifest: AnyRecord): AnyRecord {
  const family = (manifest.hookFamilies ?? []).find((entry: AnyRecord) =>
    entry.deployed !== false
    && Array.isArray(entry.pools)
    && entry.pools.length > 0
    && entry.hookAddress != null,
  );
  if (!family) throw new Error("self-test manifest has no deployed family-level hook with pools");
  return family;
}

function withBadPoolId(manifest: AnyRecord): AnyRecord {
  const mutated = structuredClone(manifest);
  const family = firstDeployedFamilyWithPools(mutated);
  family.pools[0].poolId = `0x${"f".repeat(64)}`;
  return mutated;
}

function withBadPermissionBits(manifest: AnyRecord): AnyRecord {
  const mutated = structuredClone(manifest);
  const family = firstDeployedFamilyWithPools(mutated);
  family.permissionFlagsLow14Bits = Number(family.permissionFlagsLow14Bits) ^ 1;
  return mutated;
}

function targetByNetwork(packet: AnyRecord, network: string): AnyRecord {
  return (packet.officialMultichainTargets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function main(): void {
  console.log("Uniswap v4 hook indexer metadata exporter self-test");
  console.log(`root ${ROOT}`);
  console.log("");

  cleanup();
  try {
    const manifest = readJson(MANIFEST);
    writeJson(TEMP_GOOD, manifest);
    writeJson(TEMP_BAD_POOL_ID, withBadPoolId(manifest));
    writeJson(TEMP_BAD_PERMISSION_BITS, withBadPermissionBits(manifest));

    const good = runExporter(TEMP_GOOD);
    expect(good.status === 0, "valid fixture exports metadata", good.stdout || good.stderr);
    const packet = JSON.parse(good.stdout);
    expect(packet.generatedFrom === TEMP_GOOD, "valid fixture records source manifest path", good.stdout);
    expect(packet.summary?.publishedArcTestnetPoolCount === 11, "valid fixture exports all 11 Arc testnet pools", good.stdout);
    expect(packet.summary?.officialMultichainTargetCount === 4, "valid fixture exports all four official multichain targets", good.stdout);
    expect(
      packet.officialIndexingCaveat?.selfDeployedArcTestnetIsOfficial === false,
      "valid fixture preserves the non-official Arc testnet caveat",
      good.stdout,
    );
    expect(
      targetByNetwork(packet, "arc-mainnet").status === "pending-official-uniswap-v4-addresses",
      "valid fixture keeps Arc mainnet pending in hook metadata",
      good.stdout,
    );
    expect(
      targetByNetwork(packet, "avalanche-fuji").indexingReadiness === "rehearsal-only-not-official-indexing",
      "valid fixture keeps Avalanche Fuji rehearsal-only in hook metadata",
      good.stdout,
    );
    expect(
      targetByNetwork(packet, "avalanche").contracts?.PoolManager === "0x06380c0e0912312b5150364b9dc4542ba0dbbc85",
      "valid fixture exports Avalanche official PoolManager in hook metadata",
      good.stdout,
    );
    expect(
      targetByNetwork(packet, "arbitrum-one").contracts?.PoolManager === "0x360e68faccca8ca495c1b759fd9eee466db9fb32",
      "valid fixture exports Arbitrum One official PoolManager in hook metadata",
      good.stdout,
    );

    const badPoolId = runExporter(TEMP_BAD_POOL_ID);
    expect(badPoolId.status !== 0, "bad poolId fixture fails", badPoolId.stdout || badPoolId.stderr);
    expect(
      badPoolId.stderr.includes("poolId does not derive from PoolKey"),
      "bad poolId fixture fails for the explicit PoolKey reason",
      badPoolId.stderr,
    );

    const badPermissionBits = runExporter(TEMP_BAD_PERMISSION_BITS);
    expect(badPermissionBits.status !== 0, "bad permission-bit fixture fails", badPermissionBits.stdout || badPermissionBits.stderr);
    expect(
      badPermissionBits.stderr.includes("hook low-14 bits"),
      "bad permission-bit fixture fails for the explicit low-14 reason",
      badPermissionBits.stderr,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  if (counts.FAIL > 0) process.exit(1);
}

main();
