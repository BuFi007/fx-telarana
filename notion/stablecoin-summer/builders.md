# Builder Guide

Stablecoin Summer is built around cross-chain FX credit.

## Current Flow

1. User selects source chain.
2. User selects USDC as source asset.
3. User selects destination hub market.
4. User chooses an action:
   - deposit collateral.
   - supply lending liquidity.
   - borrow setup.
5. CCTP moves USDC to the hub.
6. Hyperlane intent messaging coordinates the hub action.
7. The hub validates the action through registries.
8. The campaign engine records eligible activity.

## Important Contracts

- FxSpoke.
- FxSpokeIntentRouter.
- FxHubReceiver.
- FxHubIntentReceiver.
- AssetRegistry.
- SpokeRegistry.
- FxMarketRegistry.
- OracleRegistry.
- CampaignRegistry.
- CampaignPointsEngine.
- RewardEligibilityEngine.

## Design Rule

Hyperlane can be permissionless.

Collateral acceptance cannot be permissionless.

Every asset must pass through registry, oracle, and risk validation before becoming eligible collateral or borrow liquidity.
