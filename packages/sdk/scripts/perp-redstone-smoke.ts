#!/usr/bin/env bun
// SPDX-License-Identifier: Apache-2.0

// Exercises the full Arc perp trading smoke with RedStone-wrapped
// flagAccount/liquidate calls. Kept as a separate operator entrypoint because
// the sprint-1 ship gate is specifically the production RedStone calldata path.
await import("./perp-arc-trading-smoke.js");
