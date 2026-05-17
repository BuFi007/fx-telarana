// SPDX-License-Identifier: AGPL-3.0-only
import { createCorsMiddleware, errorHandler, notFoundHandler, requestContext } from "@bufinance/worker-base/middleware";
import { FxTelaranaError } from "@fx-telarana/core";
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
app.onError((error, c) => {
  if (error instanceof FxTelaranaError) {
    const requestId = (c as unknown as { get(key: string): string | undefined }).get("requestId");
    const headers = new Headers({ "content-type": "application/json; charset=utf-8" });
    if (error.code === "ORACLE_STALE") headers.set("retry-after", "15");
    if (requestId) headers.set("x-request-id", requestId);
    return new Response(
      JSON.stringify({
        success: false,
        error: {
          code: error.code,
          message: error.message,
          requestId,
        },
      }),
      { status: error.status, headers }
    );
  }
  return errorHandler(error, c);
});
app.notFound(notFoundHandler);

export default app;
