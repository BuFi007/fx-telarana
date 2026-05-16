// SPDX-License-Identifier: AGPL-3.0-only
import type { Context } from "hono";
import type { StatusCode } from "hono/utils/http-status";

function replacer(_key: string, value: unknown) {
  return typeof value === "bigint" ? value.toString() : value;
}

export function json(c: Context, value: unknown, status: StatusCode = 200) {
  return c.newResponse(JSON.stringify(value, replacer), status, {
    "content-type": "application/json; charset=utf-8",
  });
}
