// SPDX-License-Identifier: AGPL-3.0-only
//
// Generates the official Arc Uniswap v4 deployment input from Uniswap's
// deployments Markdown once Arc appears there. This is read-only unless --out is
// provided. It never broadcasts transactions.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { mkdirSync } from "node:fs";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

type DeploymentSection = {
  name: string;
  chainId: number;
  contracts: Record<string, string>;
};

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_INPUT = "deployments/uniswap-v4-official-arc-input.template.json";
const DEPLOYMENTS_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments";
const DEPLOYMENTS_MARKDOWN_URL = `${DEPLOYMENTS_URL}.md`;
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

const requiredContracts = [
  "PoolManager",
  "PositionManager",
  "UniversalRouter",
  "Quoter",
  "StateView",
  "Permit2",
] as const;

const counts: Record<Severity, number> = { PASS: 0, WARN: 0, FAIL: 0 };

function record(severity: Severity, message: string): void {
  counts[severity] += 1;
  console.log(`${severity.padEnd(4)} ${message}`);
}

function pass(message: string): void {
  record("PASS", message);
}

function warn(message: string): void {
  record("WARN", message);
}

function fail(message: string): void {
  record("FAIL", message);
}

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function normalizeName(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function canonicalContractName(label: string): string | undefined {
  const normalized = normalizeName(label);
  if (normalized === "poolmanager") return "PoolManager";
  if (normalized === "positiondescriptor") return "PositionDescriptor";
  if (normalized === "positionmanager") return "PositionManager";
  if (normalized === "quoter") return "Quoter";
  if (normalized === "stateview") return "StateView";
  if (normalized === "universalrouter") return "UniversalRouter";
  if (normalized === "universalrouter211") return "UniversalRouter211";
  if (normalized === "permit2") return "Permit2";
  return undefined;
}

function fixtureMarkdownPath(): string | undefined {
  const value = process.env.UNISWAP_V4_DEPLOYMENTS_MARKDOWN_FILE;
  if (!value) return undefined;
  return isAbsolute(value) ? value : join(ROOT, value);
}

async function loadMarkdown(): Promise<string> {
  const fixturePath = fixtureMarkdownPath();
  if (fixturePath) {
    if (!existsSync(fixturePath)) {
      fail(`fixture markdown file is missing at ${fixturePath}`);
      return "";
    }
    pass(`loaded Uniswap deployments markdown fixture ${fixturePath}`);
    return readFileSync(fixturePath, "utf-8");
  }

  const response = await fetch(DEPLOYMENTS_MARKDOWN_URL);
  if (!response.ok) {
    fail(`failed to fetch ${DEPLOYMENTS_MARKDOWN_URL}: ${response.status}`);
    return "";
  }

  pass("fetched official Uniswap v4 deployments markdown");
  return response.text();
}

function parseDeploymentSections(markdown: string): DeploymentSection[] {
  const sections: DeploymentSection[] = [];
  const headingRe = /^##\s+(.+?):\s+(\d+)\s*$/gm;
  const matches = [...markdown.matchAll(headingRe)];

  for (let index = 0; index < matches.length; index += 1) {
    const match = matches[index];
    const name = match[1]?.trim() ?? "";
    const chainId = Number(match[2]);
    const bodyStart = (match.index ?? 0) + match[0].length;
    const bodyEnd = matches[index + 1]?.index ?? markdown.length;
    const body = markdown.slice(bodyStart, bodyEnd);
    const contracts: Record<string, string> = {};
    const rowRe = /^\|\s*\[([^\]]+)\]\([^)]+\)\s*\|\s*\[`(0x[0-9a-fA-F]{40})`\]/gm;

    for (const row of body.matchAll(rowRe)) {
      const canonical = canonicalContractName(row[1] ?? "");
      const address = row[2];
      if (canonical && isAddress(address)) contracts[canonical] = address;
    }

    if (name && Number.isInteger(chainId)) {
      sections.push({ name, chainId, contracts });
    }
  }

  return sections;
}

function findArcSection(sections: DeploymentSection[]): DeploymentSection | undefined {
  return sections.find((section) => {
    const normalized = normalizeName(section.name);
    return (
      section.chainId === 5_042
      || section.chainId === 5_042_002
      || normalized === "arc"
      || normalized === "arcmainnet"
      || normalized.startsWith("arcmainnet")
    );
  });
}

function collectSelfDeployedPoolManagers(manifest: AnyRecord): string[] {
  const managers = new Set<string>();
  for (const manager of Object.values(manifest.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (isAddress(manager.address)) managers.add(manager.address.toLowerCase());
  }
  return [...managers];
}

function buildInput(section: DeploymentSection): AnyRecord {
  return {
    schemaVersion: 1,
    network: "arc-mainnet",
    source: DEPLOYMENTS_URL,
    status: "official-uniswap-v4-addresses-published",
    chainId: section.chainId,
    retrievedAt: new Date().toISOString(),
    contracts: {
      PoolManager: section.contracts.PoolManager,
      PositionDescriptor: section.contracts.PositionDescriptor ?? null,
      PositionManager: section.contracts.PositionManager,
      UniversalRouter: section.contracts.UniversalRouter,
      UniversalRouter211: section.contracts.UniversalRouter211 ?? null,
      Quoter: section.contracts.Quoter,
      StateView: section.contracts.StateView,
      Permit2: section.contracts.Permit2,
    },
    notes: [
      "Generated from the official Uniswap v4 deployments Markdown.",
      "Run bun run uniswap:official-arc:input:check with OFFICIAL_ARC_DEPLOYMENT_INPUT pointing at this file before redeploying hooks.",
      "Do not reuse self-deployed Arc testnet PoolManagers for official Uniswap indexing.",
    ],
  };
}

function repoRelativePathFor(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  if (index === -1) return undefined;

  const value = process.argv[index + 1];
  if (!value) throw new Error(`${flag} requires a relative repository path`);
  if (value.startsWith("/") || value.includes("..")) {
    throw new Error(`${flag} must stay inside the repository`);
  }
  return value;
}

function checkGeneratedInput(input: AnyRecord, manifest: AnyRecord): void {
  if (input.schemaVersion === 1) pass("generated official Arc input schemaVersion is 1");
  else fail("generated official Arc input schemaVersion must be 1");

  if (input.network === "arc-mainnet") pass("generated official Arc input targets arc-mainnet");
  else fail("generated official Arc input must target arc-mainnet");

  if (input.source === DEPLOYMENTS_URL) pass("generated official Arc input source is official Uniswap deployments");
  else fail("generated official Arc input source must be official Uniswap deployments");

  if (typeof input.chainId === "number") pass(`generated official Arc chainId is ${input.chainId}`);
  else fail("generated official Arc chainId is missing");

  if (typeof input.retrievedAt === "string" && input.retrievedAt.length > 0) {
    pass("generated official Arc input records retrievedAt");
  } else {
    fail("generated official Arc input must record retrievedAt");
  }

  for (const name of requiredContracts) {
    if (isAddress(input.contracts?.[name])) pass(`generated official ${name} address is valid`);
    else fail(`generated official ${name} address is missing or invalid`);
  }

  if (String(input.contracts?.Permit2 ?? "").toLowerCase() === PERMIT2.toLowerCase()) {
    pass("generated official Permit2 matches canonical Permit2");
  } else {
    fail("generated official Permit2 must match canonical Permit2");
  }

  const poolManager = String(input.contracts?.PoolManager ?? "").toLowerCase();
  for (const selfPoolManager of collectSelfDeployedPoolManagers(manifest)) {
    if (poolManager === selfPoolManager) {
      fail(`generated official PoolManager reuses self-deployed Arc testnet PoolManager ${selfPoolManager}`);
    } else {
      pass(`generated official PoolManager does not reuse ${selfPoolManager}`);
    }
  }
}

async function main(): Promise<void> {
  console.log("Official Arc Uniswap v4 deployment input generator");
  console.log(`source ${DEPLOYMENTS_MARKDOWN_URL}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readJson(MANIFEST);
  const markdown = await loadMarkdown();
  const sections = parseDeploymentSections(markdown);

  if (sections.length > 0) pass(`parsed ${sections.length} official deployment sections`);
  else fail("official deployment sections could not be parsed");

  const arc = findArcSection(sections);
  const outPath = repoRelativePathFor("--out");

  if (!arc) {
    const pendingInput = readJson(DEFAULT_INPUT);
    if (pendingInput.status === "pending-official-uniswap-v4-addresses") {
      pass("default official Arc input remains pending while Arc is absent from docs");
    } else {
      fail("default official Arc input must remain pending while Arc is absent from docs");
    }

    if (outPath) {
      fail("--out cannot be used until official Arc appears in Uniswap deployments docs");
    } else {
      pass("no output file requested while Arc is absent");
    }

    warn("official Uniswap v4 deployments docs do not list Arc yet; generated populated input is externally pending");
    console.log("");
    console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
    process.exit(counts.FAIL > 0 ? 1 : 0);
  }

  pass(`official Uniswap v4 deployments docs include Arc as ${arc.name}: ${arc.chainId}`);
  const input = buildInput(arc);
  checkGeneratedInput(input, manifest);

  const json = `${JSON.stringify(input, null, 2)}\n`;
  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, json);
    pass(`wrote generated official Arc input to ${outPath}`);
  } else {
    pass("generated official Arc input is printable; pass --out to write it");
    console.log("");
    console.log(json.trimEnd());
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
