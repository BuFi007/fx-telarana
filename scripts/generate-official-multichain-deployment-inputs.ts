// SPDX-License-Identifier: AGPL-3.0-only
//
// Generates target-chain Uniswap v4 deployment inputs from Uniswap's official
// deployments Markdown for Arc, Avalanche Fuji, Avalanche, and Arbitrum. This
// is read-only unless --out is provided. It never broadcasts transactions.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

type DeploymentSection = {
  name: string;
  chainId: number;
  contracts: Record<string, string>;
};

type TargetDefinition = {
  network: string;
  displayName: string;
  defaultChainId: number | null;
  chainIds: number[];
  matchesName: (name: string) => boolean;
};

const ROOT = resolve(import.meta.dir, "..");
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const ARC_READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEPLOYMENTS_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments";
const DEPLOYMENTS_MARKDOWN_URL = `${DEPLOYMENTS_URL}.md`;
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

const contractFields = [
  "PoolManager",
  "PositionDescriptor",
  "PositionManager",
  "UniversalRouter",
  "UniversalRouter211",
  "Quoter",
  "StateView",
  "Permit2",
] as const;

const requiredContracts = [
  "PoolManager",
  "PositionManager",
  "UniversalRouter",
  "Quoter",
  "StateView",
  "Permit2",
] as const;

const targetDefinitions: TargetDefinition[] = [
  {
    network: "arc-mainnet",
    displayName: "Arc Mainnet",
    defaultChainId: null,
    chainIds: [5_042, 5_042_002],
    matchesName: (name) => {
      const normalized = normalizeName(name);
      return normalized === "arc" || normalized === "arcmainnet" || normalized.startsWith("arcmainnet");
    },
  },
  {
    network: "avalanche-fuji",
    displayName: "Avalanche Fuji",
    defaultChainId: 43_113,
    chainIds: [43_113],
    matchesName: (name) => normalizeName(name).includes("fuji"),
  },
  {
    network: "avalanche",
    displayName: "Avalanche C-Chain",
    defaultChainId: 43_114,
    chainIds: [43_114],
    matchesName: (name) => normalizeName(name) === "avalanchecchain",
  },
  {
    network: "arbitrum-one",
    displayName: "Arbitrum One",
    defaultChainId: 42_161,
    chainIds: [42_161],
    matchesName: (name) => normalizeName(name) === "arbitrumone",
  },
];

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

function findTargetSection(sections: DeploymentSection[], definition: TargetDefinition): DeploymentSection | undefined {
  return sections.find((section) => definition.chainIds.includes(section.chainId) || definition.matchesName(section.name));
}

function collectSelfDeployedPoolManagers(multichain: AnyRecord, arcReadiness: AnyRecord): string[] {
  const managers = new Set<string>();
  for (const value of multichain.selfDeployedPoolManagers?.arcTestnet ?? []) {
    if (isAddress(value)) managers.add(value.toLowerCase());
  }

  const rehearsal = multichain.selfDeployedPoolManagers?.avalancheFujiRehearsalPoolManager;
  if (isAddress(rehearsal)) managers.add(rehearsal.toLowerCase());

  for (const manager of Object.values(arcReadiness.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (isAddress(manager.address)) managers.add(manager.address.toLowerCase());
  }

  return [...managers];
}

function emptyContracts(): Record<typeof contractFields[number], null> {
  return {
    PoolManager: null,
    PositionDescriptor: null,
    PositionManager: null,
    UniversalRouter: null,
    UniversalRouter211: null,
    Quoter: null,
    StateView: null,
    Permit2: null,
  };
}

function buildPublishedTarget(definition: TargetDefinition, section: DeploymentSection): AnyRecord {
  return {
    network: definition.network,
    displayName: definition.displayName,
    chainId: section.chainId,
    status: "official-uniswap-v4-addresses-published",
    source: DEPLOYMENTS_URL,
    sourceSection: `${section.name}: ${section.chainId}`,
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
    indexingReadiness: "official-contracts-known-hook-pool-publication-pending",
    poolPublicationStatus: "pending-poolmanager-initialize-and-first-liquidity",
    notes: [
      "Generated from the official Uniswap v4 deployments Markdown.",
      "Official contract addresses alone do not prove fx-Telarana hook indexing.",
      "Before claiming indexing, remine/redeploy hooks, initialize pools on this PoolManager, add first liquidity, and verify StateView/subgraph/Quoter evidence.",
    ],
  };
}

function buildPendingTarget(definition: TargetDefinition): AnyRecord {
  return {
    network: definition.network,
    displayName: definition.displayName,
    chainId: definition.defaultChainId,
    status: "pending-official-uniswap-v4-addresses",
    source: DEPLOYMENTS_URL,
    contracts: emptyContracts(),
    indexingReadiness:
      definition.network === "avalanche-fuji"
        ? "rehearsal-only-not-official-indexing"
        : "not-indexable-yet-official-uniswap-v4-addresses-pending",
    poolPublicationStatus: "pending-official-uniswap-v4-addresses",
    notes: [
      "Official Uniswap v4 deployments Markdown does not list this target yet.",
      "Do not use self-deployed or rehearsal PoolManagers for official Uniswap indexing claims.",
    ],
  };
}

function checkGeneratedTarget(target: AnyRecord, selfPoolManagers: string[]): void {
  if (target.source === DEPLOYMENTS_URL) pass(`${target.network} source is official Uniswap deployments`);
  else fail(`${target.network} source must be official Uniswap deployments`);

  if (target.status === "pending-official-uniswap-v4-addresses") {
    const populated = Object.values(target.contracts ?? {}).filter((value) => value != null);
    if (populated.length === 0) pass(`${target.network} pending contracts stay unset`);
    else fail(`${target.network} pending contracts must stay unset`);
    warn(`${target.displayName} remains externally pending on official Uniswap v4 deployments`);
    return;
  }

  if (target.status === "official-uniswap-v4-addresses-published") {
    pass(`${target.network} official v4 addresses are generated`);
  } else {
    fail(`${target.network} has unexpected status ${String(target.status)}`);
  }

  for (const name of requiredContracts) {
    if (isAddress(target.contracts?.[name])) pass(`${target.network} ${name} address is valid`);
    else fail(`${target.network} ${name} address is missing or invalid`);
  }

  if (sameAddress(target.contracts?.Permit2, PERMIT2)) {
    pass(`${target.network} Permit2 is canonical`);
  } else {
    fail(`${target.network} Permit2 must match canonical Permit2`);
  }

  for (const selfPoolManager of selfPoolManagers) {
    if (sameAddress(target.contracts?.PoolManager, selfPoolManager)) {
      fail(`${target.network} PoolManager reuses self-deployed/rehearsal PoolManager ${selfPoolManager}`);
    } else {
      pass(`${target.network} PoolManager does not reuse ${selfPoolManager}`);
    }
  }
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

async function main(): Promise<void> {
  console.log("Official Uniswap v4 multichain deployment input generator");
  console.log(`source ${DEPLOYMENTS_MARKDOWN_URL}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const multichain = readJson(MULTICHAIN_MANIFEST);
  const arcReadiness = readJson(ARC_READINESS_MANIFEST);
  const markdown = await loadMarkdown();
  const sections = parseDeploymentSections(markdown);
  const selfPoolManagers = collectSelfDeployedPoolManagers(multichain, arcReadiness);

  if (sections.length > 0) pass(`parsed ${sections.length} official deployment sections`);
  else fail("official deployment sections could not be parsed");

  if (selfPoolManagers.length >= 3) {
    pass("self-deployed/rehearsal PoolManagers are available for reuse rejection");
  } else {
    fail("expected Arc testnet and Fuji rehearsal PoolManagers for reuse rejection");
  }

  const targets = targetDefinitions.map((definition) => {
    const section = findTargetSection(sections, definition);
    if (section) {
      pass(`official docs include ${definition.displayName} as ${section.name}: ${section.chainId}`);
      return buildPublishedTarget(definition, section);
    }

    pass(`official docs do not list ${definition.displayName}; generated target stays pending`);
    return buildPendingTarget(definition);
  });

  for (const target of targets) {
    checkGeneratedTarget(target, selfPoolManagers);
  }

  const generated = {
    schemaVersion: 1,
    source: DEPLOYMENTS_URL,
    sourceMarkdown: DEPLOYMENTS_MARKDOWN_URL,
    generatedAt: new Date().toISOString(),
    targets,
    notes: [
      "Use this generated bundle as the source for target-chain official deployment inputs.",
      "Official contract addresses alone do not prove hook indexing; use the pool-publication gate before claiming indexed pools.",
      "Ready claims require target-chain official PoolManager initialize receipts, first-liquidity receipts, StateView evidence, subgraph evidence, and Quoter/custom-route evidence.",
    ],
  };

  const outPath = repoRelativePathFor("--out");
  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, `${JSON.stringify(generated, null, 2)}\n`);
    pass(`wrote generated multichain deployment input bundle to ${outPath}`);
  } else {
    pass("generated multichain deployment input bundle is valid; pass --out to write it");
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
