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
});
