// SPDX-License-Identifier: AGPL-3.0-only
//
// fx-telarana HTTP gateway entry point.
//
// Wraps @bu/fx-engine pure builders (planSupply, planBorrow, planEnterHub,
// buildGatewayBurnIntent) in REST endpoints so downstream services
// (fx-pasillo as the B2B API gateway, BUFX as the execution layer) can
// consume Telarana without bundling the SDK + its viem transitive deps
// into their own runtimes.
//
// Auth: shared-secret X-API-Key header (TELARANA_API_KEY env). This is an
// INTERNAL service-to-service auth, not a B2B Clerk integration. Pasillo
// holds the secret and forwards/transforms requests; B2B integrators
// never hit this gateway directly.
//
// Runtime: Bun. Single-file entry, no compile step needed in dev.
// Deployment target: Fly.io / Render / equivalent (NOT Cloudflare Workers
// since this service may grow to do onchain RPC reads that are cheaper
// on a long-lived runtime than per-request CF Workers).

import { Hono } from 'hono';
import { logger } from 'hono/logger';
import { secureHeaders } from 'hono/secure-headers';
import { HTTPException } from 'hono/http-exception';
import { authMiddleware } from './middleware/auth.ts';
import calldataRoutes from './routes/calldata.ts';
import marketsRoutes from './routes/markets.ts';

const app = new Hono();

app.use('*', secureHeaders());
app.use('*', logger());

// Health is public — no auth, no rate limit. Pasillo polls this on boot
// to decide whether to instantiate the TelaranaProvider.
app.get('/health', (c) =>
	c.json({
		success: true,
		service: 'fx-telarana-api',
		status: 'ok',
		timestamp: new Date().toISOString(),
		version: process.env.npm_package_version ?? '0.1.0',
	}),
);

// Everything else gates on the shared secret.
app.use('*', authMiddleware);

// Markets metadata (hubs, FxMarketRegistry IDs, supported pairs).
app.route('/markets', marketsRoutes);

// Calldata builders (wraps SDK plan* functions).
app.route('/calldata', calldataRoutes);

app.onError((err, c) => {
	if (err instanceof HTTPException) {
		return c.json({ success: false, error: { message: err.message, status: err.status } }, err.status);
	}
	console.error('[fx-telarana-api] unhandled error', err);
	return c.json(
		{ success: false, error: { message: err.message ?? 'internal error', status: 500 } },
		500,
	);
});

app.notFound((c) => c.json({ success: false, error: { message: 'not found', status: 404 } }, 404));

const port = Number(process.env.PORT ?? 4040);
console.log(`[fx-telarana-api] listening on :${port}`);

export default {
	port,
	fetch: app.fetch,
};
