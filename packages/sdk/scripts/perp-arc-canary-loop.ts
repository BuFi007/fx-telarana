#!/usr/bin/env bun
// SPDX-License-Identifier: Apache-2.0

import { keeperOptionsFromEnv, runFxPerpKeeperLoop } from "../src/perps-keeper.js";

const abort = new AbortController();
process.once("SIGINT", () => abort.abort());
process.once("SIGTERM", () => abort.abort());

await runFxPerpKeeperLoop({
  ...keeperOptionsFromEnv(),
  components: ["canary"],
  signal: abort.signal,
});
