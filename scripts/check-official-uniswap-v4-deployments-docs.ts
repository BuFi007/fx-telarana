// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only freshness check for the official Uniswap v4 deployments docs.
// This catches address drift for published targets and catches newly published
// Arc/Fuji official deployments that require local manifest updates.

import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

type DeploymentSection = {
  name: string;
  chainId: number;
  contracts: Record<string, string>;
};

const ROOT = resolve(import.meta.dir, "..");
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const DEPLOYMENTS_MARKDOWN_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments.md";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

const publishedTargets = [
  { network: "avalanche", displayName: "Avalanche C-Chain", chainId: 43114 },
  { network: "arbitrum-one", displayName: "Arbitrum One", chainId: 42161 },
] as const;

const pendingTargets = [
  {
    network: "arc-mainnet",
    displayName: "Arc mainnet",
    chainIds: [5042, 5_042_002],
    matchesName: (name: string) => {
      const normalized = normalizeName(name);
      return normalized === "arc" || normalized === "arcmainnet" || normalized.startsWith("arcmainnet");
    },
  },
  {
    network: "avalanche-fuji",
    displayName: "Avalanche Fuji",
    chainIds: [43_113],
    matchesName: (name: string) => normalizeName(name).includes("fuji"),
  },
] as const;

const contractFields = [
  "PoolManager",
  "PositionDescriptor",
  "PositionManager",
  "Quoter",
  "StateView",
  "UniversalRouter",
  "UniversalRouter211",
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

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
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

  const markdown = await response.text();
  pass("fetched official Uniswap v4 deployments markdown");
  return markdown;
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

function targetByNetwork(manifest: AnyRecord, network: string): AnyRecord {
  const target = (manifest.targets ?? []).find((entry: AnyRecord) => entry.network === network);
  if (!target) fail(`multichain manifest missing ${network}`);
  return target ?? {};
}

function findSectionByChainId(sections: DeploymentSection[], chainId: number): DeploymentSection | undefined {
  return sections.find((section) => section.chainId === chainId);
}

function checkPublishedTarget(manifest: AnyRecord, sections: DeploymentSection[], expected: typeof publishedTargets[number]): void {
  const target = targetByNetwork(manifest, expected.network);
  const section = findSectionByChainId(sections, expected.chainId);

  if (section) pass(`official docs include ${expected.displayName} chainId ${expected.chainId}`);
  else {
    fail(`official docs are missing ${expected.displayName} chainId ${expected.chainId}`);
    return;
  }

  if (target.status === "official-uniswap-v4-addresses-published") {
    pass(`${expected.network} manifest marks official v4 addresses as published`);
  } else {
    fail(`${expected.network} manifest must mark official v4 addresses as published`);
  }

  if (target.officialDocsListedOn2026_06_08 === true) {
    pass(`${expected.network} manifest records the official docs listing flag`);
  } else {
    fail(`${expected.network} manifest official docs listing flag is missing`);
  }

  for (const field of contractFields) {
    const manifestAddress = target.contracts?.[field];
    const docsAddress = section.contracts[field];
    if (!isAddress(manifestAddress)) {
      fail(`${expected.network} ${field} is missing from manifest`);
    } else if (!isAddress(docsAddress)) {
      fail(`${expected.network} ${field} is missing from official docs parser`);
    } else if (sameAddress(manifestAddress, docsAddress)) {
      pass(`${expected.network} ${field} matches official docs`);
    } else {
      fail(`${expected.network} ${field} manifest=${manifestAddress} docs=${docsAddress}`);
    }
  }
}

function findPendingSection(sections: DeploymentSection[], pending: typeof pendingTargets[number]): DeploymentSection | undefined {
  return sections.find((section) => pending.chainIds.includes(section.chainId) || pending.matchesName(section.name));
}

function checkPendingTarget(manifest: AnyRecord, sections: DeploymentSection[], pending: typeof pendingTargets[number]): void {
  const target = targetByNetwork(manifest, pending.network);
  const section = findPendingSection(sections, pending);

  if (section) {
    fail(`official docs now include ${pending.displayName} as ${section.name}: ${section.chainId}; update local manifests before claiming readiness`);
  } else {
    pass(`official docs do not list ${pending.displayName} yet`);
  }

  if (target.status === "pending-official-uniswap-v4-addresses") {
    pass(`${pending.network} manifest remains pending official v4 addresses`);
  } else {
    fail(`${pending.network} manifest status should be pending unless official docs list it`);
  }

  const contracts = target.contracts ?? {};
  const populated = Object.entries(contracts).filter(([, value]) => value != null);
  if (populated.length === 0) {
    pass(`${pending.network} manifest official contract addresses stay unset`);
  } else {
    fail(`${pending.network} manifest has populated official contracts while docs are pending`);
  }

  if (!section) warn(`${pending.displayName} remains externally pending on official Uniswap v4 deployments`);
}

async function main(): Promise<void> {
  console.log("Official Uniswap v4 deployments docs freshness check");
  console.log(`source ${DEPLOYMENTS_MARKDOWN_URL}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readJson(MULTICHAIN_MANIFEST);
  const markdown = await loadMarkdown();
  const sections = parseDeploymentSections(markdown);

  if (manifest.source === "https://developers.uniswap.org/docs/protocols/v4/deployments") {
    pass("multichain manifest source is the official deployments page");
  } else {
    fail("multichain manifest source must be the official deployments page");
  }

  if (sections.length > 0) pass(`parsed ${sections.length} official deployment sections`);
  else fail("official deployment sections could not be parsed");

  for (const expected of publishedTargets) {
    checkPublishedTarget(manifest, sections, expected);
  }

  for (const pending of pendingTargets) {
    checkPendingTarget(manifest, sections, pending);
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
