// SPDX-License-Identifier: AGPL-3.0-only
import { serve } from "@hono/node-server";

import app from "./index.js";

const port = Number(process.env.PORT ?? 3002);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`@fx-telarana/api listening on http://localhost:${info.port}`);
});
