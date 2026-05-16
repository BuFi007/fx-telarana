// SPDX-License-Identifier: MIT
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { NextConfig } from "next";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../..");

const nextConfig: NextConfig = {
  transpilePackages: ["@fx-telarana/core"],
  turbopack: {
    root: repoRoot,
  },
};

export default nextConfig;
