// SPDX-License-Identifier: AGPL-3.0-only
//
// Markets metadata. v1 returns the static hub + spoke registry from
// @bu/fx-engine. v2 will read live on-chain market state (utilization,
// borrow rate, supply rate) so Pasillo's yield surface can quote APYs.

import { Hono } from 'hono';
import { getAddresses } from '@bu/fx-engine';

const route = new Hono();

const HUB_CHAIN_IDS = [43113, 5042002] as const; // Fuji + Arc
const SPOKE_CHAIN_IDS = [
	11155111, // Sepolia
	11155420, // OP Sepolia
	421614, // Arbitrum Sepolia
	80002, // Polygon Amoy
	1301, // Unichain Sepolia
	4801, // Worldchain Sepolia
	43113, // Fuji local spoke
	5042002, // Arc local spoke
] as const;

route.get('/hubs', (c) => {
	const hubs = HUB_CHAIN_IDS.map((chainId) => {
		const a = getAddresses(chainId as never);
		return {
			chainId,
			name: chainId === 43113 ? 'Avalanche Fuji' : 'Arc Testnet',
			role: chainId === 43113 ? 'primary-money-market' : 'trading-execution',
			fxMarketRegistry: a.fxMarketRegistry ?? null,
			fxHubMessageReceiver: (a as Record<string, unknown>).fxHubMessageReceiver ?? null,
			fxGatewayHook: (a as Record<string, unknown>).fxGatewayHook ?? null,
			fxOracle: (a as Record<string, unknown>).fxOracle ?? null,
			fxLiquidator: (a as Record<string, unknown>).fxLiquidator ?? null,
			tokens: {
				USDC: (a as Record<string, unknown>).USDC ?? null,
				EURC: (a as Record<string, unknown>).EURC ?? null,
			},
		};
	});
	return c.json({ success: true, data: hubs });
});

route.get('/spokes', (c) => {
	const spokes = SPOKE_CHAIN_IDS.map((chainId) => {
		const a = getAddresses(chainId as never);
		return {
			chainId,
			fxSpokeToFuji: (a as Record<string, unknown>).fxSpokeToFuji ?? null,
			fxSpokeToArc: (a as Record<string, unknown>).fxSpokeToArc ?? null,
		};
	});
	return c.json({ success: true, data: spokes });
});

// Static pair catalog — v2 will be derived from on-chain market state.
route.get('/pairs', (c) =>
	c.json({
		success: true,
		data: [
			{
				marketId: 'fuji-eurc-usdc',
				chainId: 43113,
				loanToken: 'EURC',
				collateralToken: 'USDC',
				note: 'Borrow EURC against USDC collateral on Fuji hub.',
			},
			{
				marketId: 'fuji-usdc-eurc',
				chainId: 43113,
				loanToken: 'USDC',
				collateralToken: 'EURC',
				note: 'Borrow USDC against EURC collateral on Fuji hub.',
			},
			{
				marketId: 'arc-eurc-usdc',
				chainId: 5042002,
				loanToken: 'EURC',
				collateralToken: 'USDC',
				note: 'Borrow EURC against USDC collateral on Arc hub.',
			},
			{
				marketId: 'arc-usdc-eurc',
				chainId: 5042002,
				loanToken: 'USDC',
				collateralToken: 'EURC',
				note: 'Borrow USDC against EURC collateral on Arc hub.',
			},
		],
	}),
);

export default route;
