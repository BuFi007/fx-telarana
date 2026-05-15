# Circle USDC / EURC Addresses

Last verified: 2026-05-15.
Source of truth: Circle developer docs for USDC and EURC contract addresses.

Use these addresses for hub/spoke deploy configuration. Do not infer EURC support
from USDC support: EURC is live on fewer chains.

## Mainnet EVM Chains

| Chain | Chain ID | USDC | EURC | Notes |
|---|---:|---|---|---|
| Ethereum | `1` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c` | Circle issuer contracts. |
| Avalanche C-Chain | `43114` | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` | `0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD` | Primary mainnet hub target. |
| Base | `8453` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42` | Circle issuer contracts. |
| OP Mainnet | `10` | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | n/a | USDC spoke only unless/until Circle lists EURC. |
| Arbitrum One | `42161` | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | n/a | USDC spoke only unless/until Circle lists EURC. |
| Polygon PoS | `137` | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | n/a | USDC spoke only unless/until Circle lists EURC. |
| Unichain | `130` | `0x078D782b760474a361dDA0AF3839290b0EF57AD6` | n/a | USDC spoke only unless/until Circle lists EURC. |
| World Chain | `480` | `0x79A02482A880bCe3F13E09da970dC34dB4cD24D1` | `0x1C60ba0A0eD1019e8Eb035E6daF4155A5cE2380B` | Circle issuer contracts. |
| Linea | `59144` | `0x176211869cA2b568f2A7D4EE941E073a821EE1ff` | n/a | USDC spoke only unless/until Circle lists EURC. |
| Sonic | `146` | `0x29219dd400f2Bf60E5a23d13Be72B486D4038894` | n/a | USDC spoke only unless/until Circle lists EURC. |

## Testnet Anchors Used By This Repo

| Testnet | Chain ID | USDC | EURC | Notes |
|---|---:|---|---|---|
| Arc Testnet | `5042002` | `0x3600000000000000000000000000000000000000` | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | Real Circle testnet tokens. |
| Avalanche Fuji | `43113` | `0x5425890298aed601595a70AB815c96711a31Bc65` | `0x5E44db7996c682E92a960b65AC713a54AD815c6B` | Real Circle testnet tokens. Do not deploy `MockEURC`. |
| Ethereum Sepolia | `11155111` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | `0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4` | Real Circle testnet tokens. |
| Base Sepolia | `84532` | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | `0x808456652fdb597867f38412077A9182bf77359F` | Real Circle testnet tokens. |
| World Chain Sepolia | `4801` | `0x66145f38cBAC35Ca6F1Dfb4914dF98F1614aeA88` | `0xe479EcA5740Ac65d6E1823bea2f1C08Bc14e954F` | Real Circle testnet tokens. |

## Deployment Rule

- Use real Circle USDC and EURC wherever Circle has published them.
- Use `MockStablecoin` only for non-Circle basket assets that are not deployed on
  the target testnet: `mAUDF`, `mJPYC`, `mMXNB`, `mKRW1`, and `mZCHF`.
- Do not deploy or route through `MockEURC` on Arc Testnet, Avalanche Fuji,
  Ethereum Sepolia, Base Sepolia, or World Chain Sepolia.
