#!/usr/bin/env bun
// SPDX-License-Identifier: Apache-2.0

import {
  keeperComponentsFromString,
  keeperOptionsFromEnv,
  runFxPerpKeeperLoop,
} from "../src/perps-keeper.js";

const abort = new AbortController();
process.once("SIGINT", () => abort.abort());
process.once("SIGTERM", () => abort.abort());

const components = keeperComponentsFromString(process.argv[2] ?? process.env.PERP_KEEPER_COMPONENTS);
await runFxPerpKeeperLoop({
  ...keeperOptionsFromEnv(),
  components,
  signal: abort.signal,
});
