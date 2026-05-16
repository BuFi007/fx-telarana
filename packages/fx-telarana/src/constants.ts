// SPDX-License-Identifier: AGPL-3.0-only
export const WAD = 10n ** 18n;
export const ORACLE_PRICE_SCALE = 10n ** 36n;
export const MAX_UINT_256 = (1n << 256n) - 1n;

/**
 * Mirrors the gateway signer policy name used in operations docs.
 * The lending backend treats Unix-second deadlines as the practical
 * block-equivalent window until Circle Gateway moves to contract 1271.
 */
export const GATEWAY_SIGNER_BLOCK_WINDOW = 7_200;
export const MAX_INTENT_DEADLINE_SECONDS = GATEWAY_SIGNER_BLOCK_WINDOW;

export const GATEWAY_SIGNER_ALLOW_BYPASS_ENV = "GATEWAY_SIGNER_ALLOW_BYPASS";

export const DEFAULT_QUOTE_STALE_AFTER_SECONDS = 120;
