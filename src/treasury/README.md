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
├── RescueManager.sol            ← multisig + 7-day timelock for emergency ops
├── compliance/
│   ├── GlobalIdentityRegistry.sol     ← per-user KYC status, level, country
│   └── ProductEligibilityRegistry.sol ← per-(product, user) eligibility checks
├── interfaces/                  ← see commit history for details
└── libraries/
    ├── TreasuryErrors.sol
    └── TreasuryRoles.sol
```

## Core invariants

- **I1 — strict 1:1 backing.** `BrivoVault.totalAssets() >= BrivoVault.totalSupply()`.
  In normal operation `==` holds; `>=` can hold transiently if the
  operator over-delivers underlying (the excess is reclaimable by the
  rescue manager via `ReclaimExcess`).
- **I2 — share price never drops.** `convertToAssets(x) == x` and
  `convertToShares(x) == x` at all times. The product is non-rebasing;
  yield accrues through the *price* of the underlying in USDC, not
  through a changing share/asset ratio.
- **I3 — no transfer to non-eligible accounts.** `_update` calls
  `ProductEligibilityRegistry.checkEligibility(productId, to)` and (for
  transfers) `(productId, from)`. Burn (`to == 0`) skips the check so a
  blocklisted user can still exit through the redemption queue.
- **I4 — refundable subscriptions.** A queued subscription past
  `expiresAt` is unconditionally refundable to the user (USDC). Cancel
  is callable even when the queue is paused.
- **I5 — redemption censorship resistance.** If the operator skips a
  user's redemption order, the user can `cancel` and recover their
  brvUSTY immediately. Strict FIFO is not enforced on-chain in V1 — it
  is an operator SLA backed by the cancel/expire safety net.
- **I6 — emergency redemption is bounded.** `RescueManager` enforces
  `MAX_HAIRCUT_BPS = 500` (5%) so the worst-case admin-driven
  redemption rate is no less than `NAV * 0.95`.

## Trust model (V1)

| Actor | Role | Powers | Mitigations |
|---|---|---|---|
| User | (none) | Subscribe, cancel, redeem, transfer to eligible peers | KYC + product eligibility |
| Operator | `OPERATOR_ROLE` (Gnosis Safe ≥2/3) | Execute queued orders after off-chain USDC↔USDY swap | `minSharesOut` / `minUsdcOut` slippage floor, execution window |
| KYC Operator | `KYC_OPERATOR_ROLE` | Register / suspend / revoke identities | Cannot move funds, cannot upgrade |
| Product Admin | `PRODUCT_ADMIN_ROLE` | Register products, configure eligibility | Cannot move funds |
| Treasury Admin | `TREASURY_ADMIN_ROLE` (Gnosis Safe ≥3/5) | Pause, grant roles, configure fees, swap NAV oracle | Cannot mint outside the vault flow |
| Rescue Council | `RESCUE_ROLE` (Gnosis Safe ≥3/5) + 7-day timelock | Pause, freeze product, set haircut, reclaim excess | 7-day delay, on-chain announcement |

## Status

- ✅ Commit 1 — scaffold (interfaces + libraries + compliance registries)
- ✅ Commit 2 — `BrivoVault` + unit tests
- ✅ Commit 3 — `SubscriptionQueue` + `RedemptionQueue` + unit tests
- ✅ Commit 4 — `TreasuryFeeCollector` + `NAVOracle` + `RescueManager` + deploy script
- ⏳ TBD — fork test against real USDY mainnet (requires whitelisted
  holder for `transferFrom`)

## Build & test

Treasury contracts compile and test as part of the standard Foundry flow
(same `foundry.toml` as Bondary Financing):

```bash
forge build
forge test -vvv --match-path 'test/treasury/**'
```

## Sepolia deployment

```bash
export DEPLOYER_PRIVATE_KEY="0x..."
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<KEY>"
export BRIVO_TREASURY_ADMIN_SEPOLIA="0x..."
export BRIVO_TREASURY_KYC_OPERATOR_SEPOLIA="0x..."
export BRIVO_TREASURY_OPERATOR_SEPOLIA="0x..."
export BRIVO_TREASURY_OPERATOR_TREASURY_SEPOLIA="0x..."
export BRIVO_TREASURY_RESCUER_SEPOLIA="0x..."
export ETHERSCAN_API_KEY="..."

forge script script/treasury/DeployTreasurySepolia.s.sol:DeployTreasurySepolia \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

The script logs all 10 contract addresses at the end. Paste them into
your dapp's `.env.local`.

## Post-deployment checklist

After `DeployTreasurySepolia` completes:

1. **KYC operator** registers test investors via
   `GlobalIdentityRegistry.registerIdentity` or `batchRegister`.
2. **Operator** funds its Safe with mock USDC and mock USDY (mint via
   `MockToken.mint`).
3. **Operator** approves the SubscriptionQueue for USDY:
   `usdy.approve(subQueue, type(uint256).max)`.
4. **Operator** approves the RedemptionQueue for USDC:
   `usdc.approve(redQueue, type(uint256).max)`.
5. **Frontend** wires the addresses into `.env.local` and surfaces
   `subQueue.submit / cancel`, `redQueue.submit / cancel`,
   and `vault.balanceOf(user)`.

## Mainnet caveats

- Real USDY (`0x96F6eF951840721AdBF46Ac996b59E0235CB985C`) enforces
  whitelist-based transfers per Ondo. The Brivo operator Safe must be
  on the Ondo whitelist before subscriptions can settle.
- `NAVOracle` requires a live Chainlink USDY/USD feed; until one exists,
  use `setFallbackPrice` (operator-managed) and document the trust
  assumption on the front-end.
- `subscriptionCap` and `minSubscription` should be tuned for the launch
  TVL target (10M cap / 100-share min in the Sepolia script are
  placeholders).
