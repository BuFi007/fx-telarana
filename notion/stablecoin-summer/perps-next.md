# Forex Perps: Coming Next

Stablecoin Summer begins with FX credit markets.

The next expansion is Forex perps.

## What Are Forex Perps?

Forex perpetuals let users trade synthetic leveraged exposure to currency pairs without holding the underlying currencies.

Examples:

- EUR/USD.
- USD/JPY.
- USD/MXN.
- USD/CHF.
- AUD/USD.
- USD/KRW.

## Architecture

Morpho is the balance sheet and lending layer.

Uniswap v4 hooks are the FX execution and safety layer.

The perp clearinghouse is a separate margin engine.

## Initial Perp Design

- USDC margin only.
- USDC-settled PnL.
- Pyth primary oracle.
- RedStone fallback.
- Uniswap v4 TWAP sanity check.
- Strict open interest caps.
- Insurance fund.
- Liquidation bots.
- Funding payments.
- 2-3 initial markets only.

## First Target Markets

- USD/JPY.
- USD/MXN.
- USD/CHF.

## Design Rule

Do not make Morpho the perp engine.

Morpho powers liquidity, collateral, and market-maker credit.

The perp engine handles margin, PnL, funding, liquidation, and account health.
