# DODO PMM (Solidity 0.8 port)

Three vendored library files from the DODO V2 PMM math, in their Solidity-0.8-compatible
form as maintained by Abracadabra Money (MIMSwap):

| File              | Source                                                                                                                       |
|-------------------|------------------------------------------------------------------------------------------------------------------------------|
| `DecimalMath.sol` | [Abracadabra-money/abracadabra-money-contracts@46ad8622](https://github.com/Abracadabra-money/abracadabra-money-contracts/blob/46ad8622cfe620b85473b829ca39e2bfb53f858c/src/mimswap/libraries/DecimalMath.sol) |
| `Math.sol`        | [Abracadabra-money/abracadabra-money-contracts@46ad8622](https://github.com/Abracadabra-money/abracadabra-money-contracts/blob/46ad8622cfe620b85473b829ca39e2bfb53f858c/src/mimswap/libraries/Math.sol)        |
| `PMMPricing.sol`  | [Abracadabra-money/abracadabra-money-contracts@46ad8622](https://github.com/Abracadabra-money/abracadabra-money-contracts/blob/46ad8622cfe620b85473b829ca39e2bfb53f858c/src/mimswap/libraries/PMMPricing.sol)  |

Original copyright **DODO ZOO 2020** — Apache-2.0. Same SPDX-License-Identifier header preserved
in each file. `Math.sol` is itself an adaptation of [`DODOEX/contractV2`'s `lib/Math.sol`](https://github.com/DODOEX/contractV2/blob/main/contracts/lib/Math.sol).

## Modification log

The only deviation from upstream is the import path syntax, because Abracadabra's
codebase uses a Foundry remapping (`/mimswap/libraries/...`) that doesn't apply here.
Each `import` line was rewritten to a same-directory relative path, e.g.
`import {Math} from "/mimswap/libraries/Math.sol";` → `import {Math} from "./Math.sol";`.

No algorithmic or arithmetic changes.

## Audits

The MIMSwap codebase containing these libraries was audited by Code4rena in March 2024;
findings are public at [code-423n4/2024-03-abracadabra-money-findings](https://github.com/code-423n4/2024-03-abracadabra-money-findings).
DODO V2's original PMM math has been live in production since 2020.

## Usage

Imported into the fx-Telaraña codebase via the `dodo-pmm/` remapping:

```solidity
import {PMMPricing} from "dodo-pmm/PMMPricing.sol";
```
