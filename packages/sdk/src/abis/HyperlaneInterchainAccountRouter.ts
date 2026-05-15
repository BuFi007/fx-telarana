// SPDX-License-Identifier: Apache-2.0
export const HyperlaneInterchainAccountRouterAbi = [
  {
    type: "function",
    name: "callRemote",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_destinationDomain", type: "uint32" },
      {
        name: "calls",
        type: "tuple[]",
        components: [
          { name: "to", type: "bytes32" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
    ],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    type: "function",
    name: "getRemoteInterchainAccount",
    stateMutability: "view",
    inputs: [
      { name: "_destination", type: "uint32" },
      { name: "_owner", type: "address" },
    ],
    outputs: [{ name: "", type: "address" }],
  },
] as const;
