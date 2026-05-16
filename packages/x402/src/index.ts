// SPDX-License-Identifier: AGPL-3.0-only
import { createLogger } from "@bufinance/logger";
import type { MiddlewareHandler } from "hono";

const log = createLogger({ prefix: "fx-telarana:x402" });

export type X402Receipt = {
  payer: string;
  amount: string;
  network: string;
  settlementRef?: string;
};

export type X402VerificationResult =
  | { ok: true; receipt: X402Receipt }
  | { ok: false; reason: string };

export type X402ReceiptVerifier = (args: {
  header: string;
  endpoint: string;
  priceUsdc: string;
}) => Promise<X402VerificationResult>;

export type PremiumEndpoint =
  | "historical_apy"
  | "liquidation_density"
  | "borrow_with_sim"
  | "mcp_provider_quota";

export const PREMIUM_PRICES: Record<PremiumEndpoint, string> = {
  historical_apy: "0.002",
  liquidation_density: "0.005",
  borrow_with_sim: "0.01",
  mcp_provider_quota: "0.001",
};

export async function defaultReceiptVerifier(args: {
  header: string;
  endpoint: string;
  priceUsdc: string;
}): Promise<X402VerificationResult> {
  try {
    const decoded = JSON.parse(Buffer.from(args.header, "base64").toString("utf8")) as Partial<X402Receipt>;
    if (!decoded.payer || !decoded.amount || !decoded.network) {
      return { ok: false, reason: "receipt_missing_required_fields" };
    }
    if (decoded.amount !== args.priceUsdc) {
      return { ok: false, reason: "receipt_amount_mismatch" };
    }
    const receipt: X402Receipt = {
      payer: decoded.payer,
      amount: decoded.amount,
      network: decoded.network,
    };
    if (decoded.settlementRef) {
      receipt.settlementRef = decoded.settlementRef;
    }
    return { ok: true, receipt };
  } catch {
    return { ok: false, reason: "receipt_decode_failed" };
  }
}

export function requireX402Payment(args: {
  endpoint: PremiumEndpoint;
  verifier?: X402ReceiptVerifier;
}): MiddlewareHandler {
  const priceUsdc = PREMIUM_PRICES[args.endpoint];
  const verifier = args.verifier ?? defaultReceiptVerifier;
  return async (c, next) => {
    const header = c.req.header("Payment-Signature") ?? c.req.header("X-Payment") ?? "";
    if (!header) {
      return c.json(
        {
          error: "payment_required",
          endpoint: args.endpoint,
          priceUsdc,
          message: `This endpoint requires an x402 payment receipt for ${priceUsdc} USDC.`,
        },
        402
      );
    }

    const result = await verifier({ header, endpoint: args.endpoint, priceUsdc });
    if (!result.ok) {
      log.warn(
        JSON.stringify({
          endpoint: args.endpoint,
          priceUsdc,
          status: "rejected",
          reason: result.reason,
        })
      );
      return c.json({ error: "payment_rejected", reason: result.reason }, 402);
    }

    c.set("x402Receipt" as never, result.receipt as never);
    log.info(
      JSON.stringify({
        endpoint: args.endpoint,
        priceUsdc,
        status: "paid",
        payer: result.receipt.payer,
        settlementRef: result.receipt.settlementRef,
      })
    );
    await next();
  };
}
