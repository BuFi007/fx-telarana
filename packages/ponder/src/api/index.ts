// SPDX-License-Identifier: AGPL-3.0-only
import { Hono } from "hono";

const app = new Hono();

app.get("/health", (c) =>
  c.json({
    ok: true,
    service: "@fx-telarana/ponder",
    timestamp: new Date().toISOString(),
  })
);

export default app;
