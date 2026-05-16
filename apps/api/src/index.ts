// SPDX-License-Identifier: AGPL-3.0-only
import { createCorsMiddleware, errorHandler, notFoundHandler, requestContext } from "@bufinance/worker-base/middleware";
import { Hono } from "hono";

import { createRoutes } from "./routes.js";

const app = new Hono();

app.use("*", async (c, next) => {
  const environment = process.env.ENVIRONMENT ?? (process.env.NODE_ENV === "production" ? "production" : "development");
  const currentEnv = (c as unknown as { env?: Record<string, string | undefined> }).env;
  if (currentEnv) {
    currentEnv.ENVIRONMENT ??= environment;
  } else {
    Object.defineProperty(c, "env", {
      configurable: true,
      value: { ...process.env, ENVIRONMENT: environment },
    });
  }
  await next();
});
app.use("*", requestContext());
app.use(
  "*",
  createCorsMiddleware({
    origins: {
      development: ["http://localhost:3000", "http://localhost:3001", "http://localhost:3002"],
      production: ["https://fx-telarana.bufi.finance"],
    },
    fallbackEnv: process.env.NODE_ENV === "production" ? "production" : "development",
  })
);
app.route("/", createRoutes());
app.onError(errorHandler);
app.notFound(notFoundHandler);

export default app;
