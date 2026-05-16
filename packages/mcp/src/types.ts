// SPDX-License-Identifier: AGPL-3.0-only
import type { z } from "zod";

export type JsonSchemaObject = {
  type: string;
  properties?: Record<string, unknown>;
  required?: string[];
  additionalProperties?: boolean;
  [key: string]: unknown;
};

export type ToolDef<I = unknown, O = unknown> = {
  name: string;
  description: string;
  inputSchema: z.ZodType<I>;
  jsonSchema: JsonSchemaObject;
  signedAction?: boolean;
  handler(input: I): Promise<O>;
};
