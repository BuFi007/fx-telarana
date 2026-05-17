// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { fxTelaranaTools } from "./tools.js";

describe("MCP tool registry", () => {
  test("contains read and unsigned signed-action tools", () => {
    const names = fxTelaranaTools.map((tool) => tool.name);
    expect(names).toContain("inspect_fx_telarana_market");
    expect(names).toContain("build_borrow_intent");
    expect(fxTelaranaTools.find((tool) => tool.name === "build_borrow_intent")?.signedAction).toBe(true);
  });

  test("signed-action tools expose full wallet input schemas", () => {
    for (const tool of fxTelaranaTools.filter((candidate) => candidate.signedAction)) {
      expect(tool.description).toContain("Never executes");
      expect(tool.jsonSchema.additionalProperties).toBe(false);
      expect((tool.jsonSchema.required as string[]).length).toBeGreaterThan(6);
      expect(Object.keys(tool.jsonSchema.properties ?? {})).toContain("nonce");
      expect(Object.keys(tool.jsonSchema.properties ?? {})).toContain("deadline");
    }
    expect(
      fxTelaranaTools.find((tool) => tool.name === "build_borrow_intent")?.jsonSchema.required
    ).toContain("borrowAssets");
    expect(
      fxTelaranaTools.find((tool) => tool.name === "build_withdraw_intent")?.jsonSchema.required
    ).toContain("receiver");
  });
});
