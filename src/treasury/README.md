# Brivo Treasury — Smart contracts

This directory contains the smart-contract stack for **Brivo Treasury**
(yield products wrapped 1:1 from an external accumulating underlying).
The pilot product is **Brivo US Treasury Yield (`brvUSTY`)**, backed by
[Ondo Finance `USDY`](https://ondo.finance/usdy).

It is intentionally separate from Brivo Financing (`src/CorporateBond.sol`,
`src/BondFactory.sol`, etc.). The two verticals share **no Solidity
code** at the contract level:

- Treasury never imports anything under `src/` outside of `src/treasury/`.
- Treasury has its own compliance registries (`GlobalIdentityRegistry`,
  `ProductEligibilityRegistry`). It does **not** depend on
  `ComplianceManager` (ERC-3643), which is Financing-only.
- Treasury has its own fee collector (`TreasuryFeeCollector`). It does
  **not** depend on `BondaryFeeCollector`.
- A bug or upgrade in one vertical cannot reach the other.

## Layout

```
src/treasury/
├── BrivoVault.sol               ← ERC-4626-compatible vault, 1:1 wrap of USDY
├── SubscriptionQueue.sol        ← user submits USDC → operator delivers USDY → mint brvUSTY
├── RedemptionQueue.sol          ← user submits brvUSTY → operator returns USDC → burn brvUSTY
├── TreasuryFeeCollector.sol     ← pluggable fee module (0 in V1)
├── NAVOracle.sol                ← display-only NAV (Chainlink USDY/USD + fallback)
├── RescueManager.sol            ← multisig + timelock for emergency operations
├── compliance/
│   ├── GlobalIdentityRegistry.sol     ← per-user KYC status, level, country
│   └── ProductEligibilityRegistry.sol ← per-(product, user) eligibility checks
├── interfaces/
│   ├── IBrivoVault.sol
│   ├── ISubscriptionQueue.sol
│   ├── IRedemptionQueue.sol
│   ├── ITreasuryFeeCollector.sol
│   ├── INAVOracle.sol
│   ├── IGlobalIdentityRegistry.sol
│   ├── IProductEligibilityRegistry.sol
│   └── IRescueManager.sol
└── libraries/
    ├── TreasuryErrors.sol       ← custom errors (gas-efficient)
    └── TreasuryRoles.sol        ← AccessControl role constants
```

## Core invariants

The stack enforces these invariants on-chain and verifies them in the
Foundry invariant test suite:

- **I1 — strict 1:1 backing.** At any point in time after a top-of-block
  state snapshot:
  `BrivoVault.totalAssets() == IERC20(underlying).balanceOf(BrivoVault) >= BrivoVault.totalSupply()`.
  In normal operation `==` holds; `>=` can hold transiently if the
  operator over-delivers underlying (the excess is reclaimable by the
  rescue manager).
- **I2 — share price never drops.** `BrivoVault.convertToAssets(1e18) == 1e18` at all times.
  The product is non-rebasing; yield accrues through the *price* of the
  underlying in USDC, not through a changing share/asset ratio.
- **I3 — no transfer to non-eligible accounts.** Every `_update` in
  BrivoVault checks `ProductEligibilityRegistry.isEligible(productId, to)`
  unless `to == address(0)` (burn).
- **I4 — refundable subscriptions.** A queued subscription that has not
  been executed within `MAX_EXECUTION_WINDOW` can always be cancelled by
  the user, who recovers the full USDC deposit minus gas.
- **I5 — redemptions cannot be censored individually.** The operator
  cannot pick which redemption requests to execute first; the queue is
  FIFO. Skipping a request requires pausing the entire RedemptionQueue.
- **I6 — emergency redemption is bounded.** RescueManager can force
  a redemption rate that pays no less than `min(NAV - emergencyHaircut,
  oraclePrice * 0.95)`, guaranteeing a worst-case 5%-from-oracle floor.

## Trust model (V1)

| Actor | Role | Powers | Mitigations |
|---|---|---|---|
| User | (none) | Subscribe, cancel, redeem, transfer to eligible peers | KYC + product eligibility |
| Operator | `OPERATOR_ROLE` (Gnosis Safe ≥2/3) | Execute queued subscriptions / redemptions after off-chain USDC↔USDY swap | `minSharesOut` from user, execution window, audit logs |
| KYC Operator | `KYC_OPERATOR_ROLE` | Register / suspend / revoke identities | Cannot move funds, cannot upgrade |
| Product Admin | `PRODUCT_ADMIN_ROLE` | Register products, configure eligibility | Cannot move funds, cannot upgrade |
| Treasury Admin | `TREASURY_ADMIN_ROLE` (Gnosis Safe ≥3/5) | Pause, grant roles, configure fees, swap NAV oracle | Cannot mint outside the vault flow |
| Rescue Council | `RESCUE_ROLE` (Gnosis Safe ≥3/5) + 7-day timelock | Force-redeem, freeze, propose migration | 7-day delay, on-chain announcement |

Production deployments must split `OPERATOR_ROLE`, `KYC_OPERATOR_ROLE`,
`PRODUCT_ADMIN_ROLE`, `TREASURY_ADMIN_ROLE` and `RESCUE_ROLE` across
different Gnosis Safes.

## Status

- Commit 1 — scaffold (interfaces + libraries + compliance registries) — ✅ this commit
- Commit 2 — `BrivoVault` + unit & invariant tests
- Commit 3 — `SubscriptionQueue` + `RedemptionQueue` + unit tests
- Commit 4 — `TreasuryFeeCollector` + `NAVOracle` + `RescueManager` + deploy scripts + fork tests against USDY mainnet
