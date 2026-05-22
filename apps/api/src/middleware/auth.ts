// SPDX-License-Identifier: AGPL-3.0-only
//
// Shared-secret auth for the fx-telarana HTTP gateway. Single env var
// TELARANA_API_KEY — Pasillo holds the secret, calls flow Pasillo → here.
// Multi-tenant scope/quota are NOT needed at this layer; that's Pasillo's
// concern (it owns the Clerk-based B2B identity model).

import type { Context, Next } from 'hono';
import { HTTPException } from 'hono/http-exception';

function timingSafeEqual(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) {
		diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	}
	return diff === 0;
}

export async function authMiddleware(c: Context, next: Next): Promise<Response | void> {
	const expected = process.env.TELARANA_API_KEY;
	if (!expected) {
		// Fail closed in production; in dev allow anonymous so local smoke
		// tests work without env plumbing. Match Pasillo's pattern at
		// fx-pasillo/src/middleware/clerk-api-key.ts.
		if (process.env.NODE_ENV === 'production') {
			throw new HTTPException(503, { message: 'TELARANA_API_KEY not configured' });
		}
		console.warn('[fx-telarana-api] TELARANA_API_KEY unset — accepting all requests (dev mode)');
		return next();
	}

	const provided = c.req.header('X-API-Key');
	if (!provided) {
		throw new HTTPException(401, { message: 'X-API-Key header required' });
	}

	if (!timingSafeEqual(provided, expected)) {
		throw new HTTPException(401, { message: 'invalid X-API-Key' });
	}

	await next();
}
