// SPDX-License-Identifier: AGPL-3.0-only
//
// EIP-170 deployed-bytecode size guard.
// Asserts every required hub contract's compiled artifact is below the
// 24,576-byte EVM contract-size limit. Fails CI if any required contract
// is over OR missing from the build output.

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const OUT  = join(ROOT, "contracts", "out");
const LIMIT = 24576;

// One entry per contract we require to be deployable. The build emits an
// artifact directory per source file (e.g. out/FxSwapHook.sol/), inside
// which there may be one OR more artifacts: FxSwapHook.json (single solc
// version) OR FxSwapHook.0.8.26.json + FxSwapHook.0.8.28.json (auto-
// detect multi-solc). Both shapes are valid; the guard inspects ALL of
// them and fails if any single artifact is over the limit.
const REQUIRED: Array<{ sourceDir: string; name: string }> = [
  { sourceDir: "FxSwapHook.sol",            name: "FxSwapHook" },
  { sourceDir: "FxHubMessageReceiver.sol",  name: "FxHubMessageReceiver" },
  { sourceDir: "FxMarketRegistry.sol",      name: "FxMarketRegistry" },
  { sourceDir: "FxLiquidator.sol",          name: "FxLiquidator" },
  { sourceDir: "FxGatewayHook.sol",         name: "FxGatewayHook" },
  { sourceDir: "FxOracle.sol",              name: "FxOracle" },
  { sourceDir: "FxRouter.sol",              name: "FxRouter" },
  { sourceDir: "FxReceipt.sol",             name: "FxReceipt" },
  { sourceDir: "MorphoOracleAdapter.sol",   name: "MorphoOracleAdapter" },
  { sourceDir: "FxTimelock.sol",            name: "FxTimelock" },
  { sourceDir: "FxSpoke.sol",               name: "FxSpoke" },
  { sourceDir: "FxSpokeIntentRouter.sol",   name: "FxSpokeIntentRouter" },
  { sourceDir: "FxHyperlaneHubReceiver.sol", name: "FxHyperlaneHubReceiver" },
  { sourceDir: "TelaranaGatewayHubHook.sol", name: "TelaranaGatewayHubHook" },
];

let exitCode = 0;
let checked = 0;

for (const { sourceDir, name } of REQUIRED) {
  const dir = join(OUT, sourceDir);
  if (!existsSync(dir)) {
    console.error(`MISSING ${sourceDir} — directory not found in build output`);
    exitCode = 1;
    continue;
  }
  const matches = readdirSync(dir).filter(
    (f) => f === `${name}.json` || (f.startsWith(`${name}.`) && f.endsWith(".json"))
  );
  if (matches.length === 0) {
    console.error(`MISSING ${name} — no artifact in ${sourceDir}`);
    exitCode = 1;
    continue;
  }
  for (const file of matches) {
    const path = join(dir, file);
    const json = JSON.parse(readFileSync(path, "utf-8"));
    const hex = json.deployedBytecode?.object;
    if (!hex || typeof hex !== "string") {
      console.error(`MALFORMED ${file} — missing deployedBytecode.object`);
      exitCode = 1;
      continue;
    }
    const size = hex.startsWith("0x") ? (hex.length - 2) / 2 : hex.length / 2;
    checked += 1;
    if (size > LIMIT) {
      console.error(`FAIL ${file} = ${size} > ${LIMIT} (EIP-170)`);
      exitCode = 1;
    } else {
      console.log(`ok   ${file} = ${size}`);
    }
  }
}

if (checked < REQUIRED.length) {
  console.error(`FAIL only ${checked} of ${REQUIRED.length} required contracts checked`);
  exitCode = 1;
}

process.exit(exitCode);
