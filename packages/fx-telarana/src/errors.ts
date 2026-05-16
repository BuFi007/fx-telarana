// SPDX-License-Identifier: AGPL-3.0-only
export class FxTelaranaError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 400
  ) {
    super(message);
    this.name = "FxTelaranaError";
  }
}

export class OracleStaleError extends FxTelaranaError {
  constructor(message = "FxOracle returned a stale price") {
    super(message, "ORACLE_STALE", 503);
  }
}
