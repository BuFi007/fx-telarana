// SPDX-License-Identifier: AGPL-3.0-only
//
// Calldata-builder REST surface. Each route wraps one @bu/fx-engine
// `plan*` helper. Returns hex calldata + the target contract address +
// chainId so downstream services know where to broadcast.
//
// Money fields are decimal strings on the wire (Pasillo convention) and
// converted to bigint internally before hitting the SDK. No JS-float math.

import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import {
	planSupply,
	planBorrow,
	planSupplyCollateral,
	planWithdraw,
	planRepay,
	planEnterHub,
	getAddresses,
} from '@bu/fx-engine';

const route = new Hono();

// viem's Address + Hex types are template-literal strings (`0x${string}`).
// Zod outputs plain strings; we narrow via `.transform` after the regex
// guarantees the shape. Saves casting at every call site.
type HexAddress = `0x${string}`;
const addressSchema = z
	.string()
	.regex(/^0x[a-fA-F0-9]{40}$/, 'Must be 0x-prefixed 40 hex chars')
	.transform((s) => s as HexAddress);
const hexSchema = z
	.string()
	.regex(/^0x[a-fA-F0-9]+$/, 'Must be 0x-prefixed hex')
	.transform((s) => s as HexAddress);
const decimalAmountSchema = z
	.string()
	.regex(/^\d+$/, 'Must be a positive integer (smallest unit, e.g. micro-USDC)');
const chainIdSchema = z.number().int().positive();

function toBigInt(value: string, label: string): bigint {
	try {
		return BigInt(value);
	} catch {
		throw new HTTPException(400, { message: `${label}: cannot parse "${value}" as integer` });
	}
}

function registryAddressFor(chainId: number): `0x${string}` {
	const a = getAddresses(chainId as never);
	const reg = a.fxMarketRegistry;
	if (!reg) {
		throw new HTTPException(400, {
			message: `chainId ${chainId} has no fxMarketRegistry — not a hub chain`,
		});
	}
	return reg as `0x${string}`;
}

function spokeAddressFor(chainId: number, hubKey: 'fuji' | 'arc'): `0x${string}` {
	const a = getAddresses(chainId as never);
	const key = hubKey === 'fuji' ? 'fxSpokeToFuji' : 'fxSpokeToArc';
	const spoke = (a as Record<string, unknown>)[key] as `0x${string}` | undefined;
	if (!spoke) {
		throw new HTTPException(400, {
			message: `chainId ${chainId} has no ${key} spoke — pair not supported`,
		});
	}
	return spoke;
}

const supplyRequestSchema = z.object({
	chainId: chainIdSchema,
	loanToken: addressSchema,
	collateralToken: addressSchema,
	assets: decimalAmountSchema,
	onBehalf: addressSchema,
});

route.post('/supply', async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = supplyRequestSchema.safeParse(body);
	if (!parsed.success) {
		return c.json({ success: false, error: { message: parsed.error.issues[0]?.message ?? 'invalid request', issues: parsed.error.issues } }, 400);
	}
	const data = planSupply({
		loanToken: parsed.data.loanToken,
		collateralToken: parsed.data.collateralToken,
		assets: toBigInt(parsed.data.assets, 'assets'),
		onBehalf: parsed.data.onBehalf,
	});
	return c.json({
		success: true,
		data: {
			chainId: parsed.data.chainId,
			to: registryAddressFor(parsed.data.chainId),
			value: '0',
			calldata: data,
		},
	});
});

const borrowRequestSchema = z.object({
	chainId: chainIdSchema,
	loanToken: addressSchema,
	collateralToken: addressSchema,
	assets: decimalAmountSchema,
	onBehalf: addressSchema,
	receiver: addressSchema,
});

route.post('/borrow', async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = borrowRequestSchema.safeParse(body);
	if (!parsed.success) {
		return c.json({ success: false, error: { message: parsed.error.issues[0]?.message ?? 'invalid request', issues: parsed.error.issues } }, 400);
	}
	const data = planBorrow({
		loanToken: parsed.data.loanToken,
		collateralToken: parsed.data.collateralToken,
		assets: toBigInt(parsed.data.assets, 'assets'),
		onBehalf: parsed.data.onBehalf,
		receiver: parsed.data.receiver,
	});
	return c.json({
		success: true,
		data: {
			chainId: parsed.data.chainId,
			to: registryAddressFor(parsed.data.chainId),
			value: '0',
			calldata: data,
		},
	});
});

const supplyCollateralSchema = z.object({
	chainId: chainIdSchema,
	loanToken: addressSchema,
	collateralToken: addressSchema,
	collateral: decimalAmountSchema,
	onBehalf: addressSchema,
});

route.post('/supply-collateral', async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = supplyCollateralSchema.safeParse(body);
	if (!parsed.success) {
		return c.json({ success: false, error: { message: parsed.error.issues[0]?.message ?? 'invalid request', issues: parsed.error.issues } }, 400);
	}
	const data = planSupplyCollateral({
		loanToken: parsed.data.loanToken,
		collateralToken: parsed.data.collateralToken,
		collateral: toBigInt(parsed.data.collateral, 'collateral'),
		onBehalf: parsed.data.onBehalf,
	});
	return c.json({
		success: true,
		data: {
			chainId: parsed.data.chainId,
			to: registryAddressFor(parsed.data.chainId),
			value: '0',
			calldata: data,
		},
	});
});

const withdrawSchema = z.object({
	chainId: chainIdSchema,
	loanToken: addressSchema,
	collateralToken: addressSchema,
	shares: decimalAmountSchema,
	onBehalf: addressSchema,
	receiver: addressSchema,
});

route.post('/withdraw', async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = withdrawSchema.safeParse(body);
	if (!parsed.success) {
		return c.json({ success: false, error: { message: parsed.error.issues[0]?.message ?? 'invalid request', issues: parsed.error.issues } }, 400);
	}
	const data = planWithdraw({
		loanToken: parsed.data.loanToken,
		collateralToken: parsed.data.collateralToken,
		shares: toBigInt(parsed.data.shares, 'shares'),
		onBehalf: parsed.data.onBehalf,
		receiver: parsed.data.receiver,
	});
	return c.json({
		success: true,
		data: {
			chainId: parsed.data.chainId,
			to: registryAddressFor(parsed.data.chainId),
			value: '0',
			calldata: data,
		},
	});
});

const repaySchema = z.object({
	chainId: chainIdSchema,
	loanToken: addressSchema,
	collateralToken: addressSchema,
	assets: decimalAmountSchema,
	onBehalf: addressSchema,
});

route.post('/repay', async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = repaySchema.safeParse(body);
	if (!parsed.success) {
		return c.json({ success: false, error: { message: parsed.error.issues[0]?.message ?? 'invalid request', issues: parsed.error.issues } }, 400);
	}
	const data = planRepay({
		loanToken: parsed.data.loanToken,
		collateralToken: parsed.data.collateralToken,
		assets: toBigInt(parsed.data.assets, 'assets'),
		onBehalf: parsed.data.onBehalf,
	});
	return c.json({
		success: true,
		data: {
			chainId: parsed.data.chainId,
			to: registryAddressFor(parsed.data.chainId),
			value: '0',
			calldata: data,
		},
	});
});

const enterHubSchema = z.object({
	chainId: chainIdSchema,
	hub: z.enum(['fuji', 'arc']),
	token: addressSchema,
	amount: decimalAmountSchema,
	beneficiary: addressSchema,
	hubCalldata: hexSchema,
});

route.post('/enter-hub', async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = enterHubSchema.safeParse(body);
	if (!parsed.success) {
		return c.json({ success: false, error: { message: parsed.error.issues[0]?.message ?? 'invalid request', issues: parsed.error.issues } }, 400);
	}
	const data = planEnterHub({
		token: parsed.data.token,
		amount: toBigInt(parsed.data.amount, 'amount'),
		beneficiary: parsed.data.beneficiary,
		hubCalldata: parsed.data.hubCalldata,
	});
	return c.json({
		success: true,
		data: {
			chainId: parsed.data.chainId,
			to: spokeAddressFor(parsed.data.chainId, parsed.data.hub),
			value: '0',
			calldata: data,
		},
	});
});

export default route;
