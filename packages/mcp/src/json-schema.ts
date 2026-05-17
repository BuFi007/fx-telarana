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

const intentBaseRequired = [
  "hubChainId",
  "loanToken",
  "collateralToken",
  "spokeChainId",
  "onBehalf",
  "nonce",
  "deadline",
];

const intentBaseProperties = {
  ...marketPairJsonSchema.properties,
  spokeChainId: { type: "number" },
  onBehalf: addressProperty,
  nonce: uintStringProperty,
  deadline: { type: "number" },
};

function intentJsonSchema(extraRequired: string[], extraProperties: Record<string, unknown>) {
  return {
    type: "object",
    additionalProperties: false,
    required: [...intentBaseRequired, ...extraRequired],
    properties: {
      ...intentBaseProperties,
      ...extraProperties,
    },
  };
}

export const supplyIntentJsonSchema = intentJsonSchema(["assets"], {
  assets: uintStringProperty,
});

export const borrowIntentJsonSchema = intentJsonSchema(["borrowAssets", "receiver"], {
  borrowAssets: uintStringProperty,
  receiver: addressProperty,
});

export const repayIntentJsonSchema = intentJsonSchema(["assets"], {
  assets: uintStringProperty,
});

export const withdrawIntentJsonSchema = intentJsonSchema(["shares", "receiver"], {
  shares: uintStringProperty,
  receiver: addressProperty,
});

export const collateralIntentJsonSchema = intentJsonSchema(["collateral"], {
  collateral: uintStringProperty,
});
