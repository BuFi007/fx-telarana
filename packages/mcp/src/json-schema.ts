// SPDX-License-Identifier: AGPL-3.0-only
export const addressProperty = {
  type: "string",
  pattern: "^0x[a-fA-F0-9]{40}$",
};

export const uintStringProperty = {
  type: "string",
  pattern: "^[0-9]+$",
};

export const marketPairJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["hubChainId", "loanToken", "collateralToken"],
  properties: {
    hubChainId: { type: "number" },
    loanToken: addressProperty,
    collateralToken: addressProperty,
  },
};
