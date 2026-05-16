// SPDX-License-Identifier: Apache-2.0
export const HyperlaneWarpRouteAbi = [
  {
    type: "function",
    name: "transferRemote",
    stateMutability: "payable",
    inputs: [
      { name: "_destination", type: "uint32" },
      { name: "_recipient", type: "bytes32" },
      { name: "_amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "quoteTransferRemote",
    stateMutability: "view",
    inputs: [
      { name: "_destination", type: "uint32" },
      { name: "_recipient", type: "bytes32" },
      { name: "_amount", type: "uint256" },
    ],
    outputs: [
      {
        name: "quotes",
        type: "tuple[]",
        components: [
          { name: "token", type: "address" },
          { name: "amount", type: "uint256" },
        ],
      },
    ],
  },
] as const;
