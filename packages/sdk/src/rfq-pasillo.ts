// SPDX-License-Identifier: Apache-2.0
import type { Address } from "viem";

import type {
  TelaranaIndexerEventSchema,
  TelaranaRequesterKind,
} from "./spot-fx.js";

export type RfqQuoteRequest = {
  quoteRequestId: string;
  requester: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  routeId?: string;
  recipient: `0x${string}`;
  deadline: number;
  metadataRef?: string;
};

export type RfqQuote = {
  quoteId: string;
  quoteRequestId: string;
  maker: `0x${string}`;
  amountOut: bigint;
  validUntil: number;
  settlementTarget?: `0x${string}`;
  metadataRef?: string;
};

export type RfqPasilloRequesterConfig = {
  requester: Address;
  requesterKind: TelaranaRequesterKind;
  allowed: boolean;
  label: string;
  metadataRef?: string;
};

export const RFQ_PASILLO_EVENT_NAMES = [
  "RfqQuoteRequested",
  "RfqQuoteAccepted",
  "RfqQuoteFilled",
] as const;

export const RFQ_PASILLO_INDEXER_SCHEMA = [
  {
    name: "RfqQuoteRequested",
    version: 1,
    fields: [
      { name: "quoteRequestId", type: "bytes32", indexed: true },
      { name: "requester", type: "address", indexed: true },
      { name: "tokenIn", type: "address", indexed: false },
      { name: "tokenOut", type: "address", indexed: false },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "routeId", type: "bytes32", indexed: false },
      { name: "recipient", type: "address", indexed: false },
      { name: "deadline", type: "uint256", indexed: false },
      { name: "metadataRef", type: "bytes32", indexed: false },
    ],
  },
  {
    name: "RfqQuoteAccepted",
    version: 1,
    fields: [
      { name: "quoteId", type: "bytes32", indexed: true },
      { name: "quoteRequestId", type: "bytes32", indexed: true },
      { name: "requester", type: "address", indexed: true },
      { name: "maker", type: "address", indexed: false },
      { name: "amountOut", type: "uint256", indexed: false },
      { name: "validUntil", type: "uint256", indexed: false },
      { name: "settlementTarget", type: "address", indexed: false },
      { name: "metadataRef", type: "bytes32", indexed: false },
    ],
  },
  {
    name: "RfqQuoteFilled",
    version: 1,
    fields: [
      { name: "quoteId", type: "bytes32", indexed: true },
      { name: "quoteRequestId", type: "bytes32", indexed: true },
      { name: "filler", type: "address", indexed: true },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "amountOut", type: "uint256", indexed: false },
    ],
  },
] as const satisfies readonly TelaranaIndexerEventSchema[];
