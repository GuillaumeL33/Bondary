# Bondary — Tokenized Corporate Bonds (ERC-3643)

Bondary is the smart-contract layer of Brivo, the European tokenized debt
infrastructure. It implements native bond issuance, peer-to-peer secondary
trading, on-chain coupons and redemptions on EVM chains.

> **Status — H1 security audit (May 2026).** All P0 security fixes from the
> first audit pass are landed (S-01 to S-06). Sepolia deployment is wired.
> See `SECURITY.md` for the full audit log.

## Stack

- **Solidity** 0.8.24, optimizer 200 runs, via_ir
- **Foundry** for build / test / script
- **OpenZeppelin** v5 (ERC20, AccessControl, Pausable, ReentrancyGuard, UUPS)
- **ERC-3643** (T-REX) for permissioned security-token transfers

## Contracts

```
src/
├── CorporateBond.sol          ← bond logic (UUPS upgradeable, 7d timelock)
├── BondFactory.sol            ← deploys ERC1967 proxies, registers bonds
├── BondaryMarketplace.sol     ← peer-to-peer order book
├── ComplianceManager.sol      ← KYC/AML registry (ERC-3643)
├── BondaryFeeCollector.sol    ← centralized fee accounting
├── interfaces/IERC3643.sol
└── mocks/
    ├── MockUSDC.sol           ← testnet 6-decimal USDC clone with faucet
    └── MockEURC.sol           ← testnet 6-decimal EURC clone with faucet

script/
├── Deploy.s.sol               ← Polygon / Ethereum mainnet deploy
└── DeploySepolia.s.sol        ← Sepolia testnet deploy (incl. mocks)

test/
├── CorporateBond.t.sol        ← lifecycle tests
├── Marketplace.t.sol          ← marketplace order flows
├── LorealSimulation.t.sol     ← end-to-end issuer simulation
└── AuditH1.t.sol              ← H1 audit-fix regression tests
```

## Build & test

```bash
forge build
forge test -vvv
```

Coverage:

```bash
forge coverage --report summary
```

Gas snapshot:

```bash
forge snapshot
```

## Deployment

### Sepolia testnet (recommended for dapp integration)

Required environment variables:

```bash
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<KEY>"
export DEPLOYER_PRIVATE_KEY="0x..."
export BONDARY_ADMIN_SEPOLIA="0x..."          # can be a plain EOA in testnet
export ETHERSCAN_API_KEY="..."                # for contract verification
```

Faucets to fund the deployer + test wallets:

- Alchemy   — https://sepoliafaucet.com
- Infura    — https://www.infura.io/faucet/sepolia
- QuickNode — https://faucet.quicknode.com/ethereum/sepolia

Deploy command:

```bash
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

The script logs all deployed addresses in a copy-pasteable block at the end.
Paste them into your dapp's `.env.local`:

```
NEXT_PUBLIC_CHAIN_ID=11155111
NEXT_PUBLIC_USDC_ADDRESS=0x…
NEXT_PUBLIC_EURC_ADDRESS=0x…
NEXT_PUBLIC_BONDARY_COMPLIANCE_ADDRESS=0x…
NEXT_PUBLIC_BONDARY_FEE_COLLECTOR_ADDRESS=0x…
NEXT_PUBLIC_BONDARY_FACTORY_ADDRESS=0x…
NEXT_PUBLIC_BONDARY_MARKETPLACE_ADDRESS=0x…
```

### Mainnet (Polygon / Ethereum)

```bash
export POLYGON_RPC_URL="https://polygon-rpc.com"
export DEPLOYER_PRIVATE_KEY="0x..."
export BONDARY_ADMIN="0x...gnosisSafe..."
export POLYGONSCAN_API_KEY="..."

forge script script/Deploy.s.sol:Deploy \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

## Post-deployment

Whoever holds the admin keys must, after deploy:

1. Grant `KYC_OPERATOR_ROLE` (on `ComplianceManager`) to the KYC backend wallet.
2. Grant `BOND_CREATOR_ROLE` (on `BondFactory`) to the ops wallet.
3. Connect the KYC provider (Sumsub / Onfido / Persona) to the operator wallet.
4. For each new bond: call `factory.createBond(name, symbol, terms, …)`.

## Security model

See `SECURITY.md` for the full threat model and audit log.

Key invariants:

- Investors can always recover deposits if the bond fails (`claimRefund`).
- Investors can always cancel subscriptions during the subscription window —
  `cancelSubscription()` is intentionally not `whenNotPaused`.
- Upgrades require a 7-day timelock (`UPGRADE_DELAY`). Both the bond proxy
  implementation and the factory's reference implementation are timelocked.
- Emergency redemption rate requires a 30-day grace period after maturity
  *and* a 7-day timelock between proposal and execution.
- Agent minting in `ACTIVE` state is capped at 1% of `totalIssuance` per
  rolling 24-hour window.

## License

MIT — see `LICENSE`.
