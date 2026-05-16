// SPDX-License-Identifier: AGPL-3.0-only
import { Hono } from "hono";

import { fxTelaranaTools } from "./tools.js";

const PROTOCOL_VERSION = "2024-11-05";

type JsonRpcRequest = {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: { name?: string; arguments?: unknown };
};

function listTools() {
  return {
    tools: fxTelaranaTools.map((tool) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: tool.jsonSchema,
    })),
  };
}

async function callTool(name: string, input: unknown) {
  const tool = fxTelaranaTools.find((candidate) => candidate.name === name);
  if (!tool) throw new Error(`Unknown tool: ${name}`);
  const parsed = tool.inputSchema.parse(input ?? {});
  const result = await tool.handler(parsed);
  return {
    content: [{ type: "text" as const, text: JSON.stringify(result, bigintReplacer, 2) }],
    isError: false,
  };
}

function bigintReplacer(_key: string, value: unknown) {
  return typeof value === "bigint" ? value.toString() : value;
}

async function handleRpc(req: JsonRpcRequest) {
  const id = req.id ?? null;
  try {
    if (req.method === "initialize") {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: "fx-telarana-mcp", version: "0.1.0" },
        },
      };
    }
    if (req.method === "tools/list") return { jsonrpc: "2.0", id, result: listTools() };
    if (req.method === "tools/call") {
      const result = await callTool(String(req.params?.name ?? ""), req.params?.arguments);
      return { jsonrpc: "2.0", id, result };
    }
    if (req.method === "ping") return { jsonrpc: "2.0", id, result: {} };
    if (req.method.startsWith("notifications/")) return null;
    return { jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${req.method}` } };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { jsonrpc: "2.0", id, error: { code: -32603, message } };
  }
}

export function createMcpApp() {
  return new Hono()
    .get("/mcp", (c) =>
      c.json({
        name: "fx-telarana/mcp",
        version: "0.1.0",
        protocolVersion: PROTOCOL_VERSION,
        endpoint: "/mcp",
        tools: fxTelaranaTools.map((tool) => tool.name),
      })
    )
    .post("/mcp", async (c) => {
      const body = (await c.req.json()) as JsonRpcRequest | JsonRpcRequest[];
      const batch = Array.isArray(body) ? body : [body];
      const responses = [];
      for (const req of batch) {
        const response = await handleRpc(req);
        if (response) responses.push(response);
      }
      if (responses.length === 0) return c.body(null, 202);
      return c.json(Array.isArray(body) ? responses : responses[0]);
    });
}
