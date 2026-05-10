# Bondary — Security Policy & Audit Log

## Reporting a vulnerability

Send a private email to `security@brivo.com` (or the canonical security
contact for the project). Do **not** open a public GitHub issue for security
disclosures. Please include:

- A clear description of the vulnerability and its impact.
- Steps to reproduce, ideally with a Foundry test or a fork-based POC.
- Your proposed fix, if any.

We commit to a 90-day responsible disclosure window: within 90 days of
acknowledgment, we ship a fix or publish an advisory explaining why a fix
isn't tractable.

## Threat model

The Bondary contracts (CorporateBond, BondFactory, BondaryMarketplace,
ComplianceManager, BondaryFeeCollector) are designed to hold investor funds
during the lifecycle of a tokenized corporate bond. The actors and trust
boundaries are:

| Actor | Trust level | Powers | Mitigations |
|---|---|---|---|
| Investor (KYC'd) | Untrusted | Subscribe, claim allocation, claim coupons, redeem, trade | Standard ERC-3643 transfer restrictions, frozen-tokens enforcement |
| Issuer (`ISSUER_ROLE`) | Semi-trusted | Pay coupons, repay principal, open early buyback | Cannot mint, burn, or upgrade |
| Bondary admin (`ADMIN_ROLE`) | Trusted multisig | Activate bond, fail bond, propose upgrade, propose emergency redemption rate | Timelocked upgrade (7d), timelocked emergency rate (7d), 30d grace period |
| Bondary agent (`AGENT_ROLE`) | Trusted multisig | Mint (capped 1%/day), burn, freeze, recover | Daily mint cap, accrual-aware burn |
| KYC operator (`KYC_OPERATOR_ROLE`) | Trusted backend | Whitelist / revoke / register identity | Cannot move funds, cannot upgrade |
| Compliance admin (`COMPLIANCE_ADMIN_ROLE`) | Trusted multisig | Bind/unbind tokens, blacklist accounts | Cannot move funds |

The default deployment grants `ADMIN_ROLE`, `AGENT_ROLE` and
`COMPLIANCE_ADMIN_ROLE` to the same Gnosis Safe (≥2/3). Production
deployments should split these into distinct multisigs.

## Audits

| Date | Auditor | Scope | Report |
|---|---|---|---|
| 2026-05 | Internal (H1 security pass) | All 5 contracts | This file |

External audits planned before mainnet:
- Trail of Bits / Spearbit / OpenZeppelin (TBD)
- Slither + Aderyn in CI

## Known limitations (production caveats)

- `ComplianceManager.whitelist(account)` registers `IIdentity(account)` with
  no claim validation. This is **acceptable for testnet only**. Production
  deployments must use the full `registerIdentity(user, identityContract,
  country)` path with a real ONCHAINID stack including
  ClaimTopicsRegistry + TrustedIssuersRegistry.
- KYC verifications **never expire** in this implementation. AML directives
  typically require periodic re-verification. To be added in a follow-up.
- No country-pair restrictions, transfer caps, or lockup periods. Modular
  compliance modules (per ERC-3643) are not yet wired.

---

## H1 audit fixes — May 2026

This release introduces the first round of post-audit security fixes
(reference: `claude/audit-h1-security-sepolia` branch).

### S-01 — Investors lose prorated coupon if maturity falls between two coupon dates

**Severity:** P0 (economic loss for holders)

**Description:** In COUPON mode, `payCoupon()` advanced `nextCouponDate`
by exactly one period. If `maturityDate` fell between two coupon dates,
the partial period `[lastCouponDate, maturityDate]` was never paid.
Investors lost up to one full coupon period of interest.

**Fix:** `repayPrincipal()` now computes and pays a "stub coupon" for the
partial period before depositing the principal. A `finalCouponPaid` flag
prevents double payment. New view `expectedFinalCouponAmount()` exposes
the stub amount before the issuer pays. New event `FinalCouponPaid`.

### S-02 — `mint()` AGENT could dilute holders without a cap

**Severity:** P0 (centralization risk if AGENT_ROLE is compromised)

**Description:** `mint(to, amount)` was accessible to `AGENT_ROLE` with no
amount limit. A compromised agent multisig could mint an arbitrary number
of bonds, diluting existing holders' coupon claims and forcing the issuer
to pay coupons on tokens that were never subscribed.

**Fix:** Daily rolling cap of `AGENT_MINT_CAP_BPS` (1%) of
`terms.totalIssuance`. `SUBSCRIPTION` state retains the full minting
ability (allocation phase). `ACTIVE` state enforces the cap. New view
`remainingAgentMintCap()` exposes the remaining headroom. New event
`AgentMintCapWindow`.

### S-03 — `setEmergencyRedemptionRate` had no timelock

**Severity:** P0 (admin can drain investors with arbitrary low rate)

**Description:** After a 30-day grace period post-maturity, the admin
could set any `redemptionRate` instantly. A compromised admin could set
it close to zero and immediately enable `redeemBonds()` exits.

**Fix:** Replaced with a propose/execute flow:
- `proposeEmergencyRedemptionRate(rate)` — admin proposes after grace.
- `executeEmergencyRedemptionRate()` — admin executes after a 7-day delay.
- `cancelEmergencyRedemptionRate()` — admin can cancel anytime.

The 7-day window gives investors time to publicly contest an unfair rate
and withdraw any other claimable funds (coupons) before redemption opens.

### S-04 — `UPGRADE_DELAY = 48h` was too short for a security token

**Severity:** P0 (compromised admin has 48h to push malicious upgrade)

**Description:** Industry standard for upgradeable contracts that hold
investor funds is 7-14 days minimum (Securitize, Tokeny T-REX, Maple
Finance). 48 hours is insufficient for incident response.

**Fix:** `UPGRADE_DELAY = 7 days` on both `CorporateBond` and
`BondFactory`. Consistent with the new `EMERGENCY_REDEMPTION_DELAY`.

### S-05 — `bindToken()` allowed arbitrary self-binding

**Severity:** P0 (registry pollution + arbitrary token registration)

**Description:** `ComplianceManager.bindToken()` accepted `msg.sender ==
token` as an authorization shortcut. Any contract could deploy itself,
declare itself a Bondary token, and emit valid `TokenBound` events
indistinguishable from real Bondary bonds.

**Fix:** `bindToken()` is restricted to `COMPLIANCE_ADMIN_ROLE`. The deploy
script grants this role to `BondFactory`. `BondFactory.createBond()` calls
`compliance.bindToken(bondProxy)` after each proxy deployment so legitimate
bonds are still bound automatically. Setting a new compliance manager via
`setCompliance()` now requires the new compliance to already declare the
token as bound.

### S-06 — `IIdentity` was not validated on registration

**Severity:** P0 (fake ONCHAINID contracts could be registered)

**Description:** `_registerIdentity()` accepted any address as
`IIdentity` without verifying it was a contract or that it declared a
management key for the user wallet.

**Fix:** When `identity != user`, the registration calls
`identity.keyHasPurpose(keccak256(user), 1)` and reverts if it returns
false or throws. The simplified `whitelist(account)` path (where
`identity == account`) keeps its prior behavior — useful for testnet
and operator-curated whitelists.

### S-08 — `BondFactory.allBonds()` could DoS clients (P1)

**Description:** Returned the full array, growing unbounded.

**Fix:** Added `allBondsPaged(offset, limit)` returning `(address[]
page, uint256 total)`. Legacy `allBonds()` retained for backward
compatibility.

---

## Storage layout

`CorporateBond` reserves a `__gap` array for future state-variable
additions. H1 added 5 state variables (agent mint window tracking, final
coupon flag, emergency redemption proposal). The gap was reduced from
`__gap[50]` to `__gap[45]`.

Future upgrades **must** preserve the storage layout: append new vars
above `__gap` and shrink the gap by the same number of slots. This is
enforced by OpenZeppelin's storage layout linter when running
`forge upgrade`.
