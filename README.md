# Ppopgi (뽑기) — Smart Contracts

This repository contains the **production smart contracts** powering **Ppopgi**, a fully on-chain, single-winner raffle (lottery-style) protocol deployed on **Etherlink (Tezos L2)**.

The contracts are designed to be:
- **Non-custodial**
- **Permissionless**
- **Deterministic**
- **Resilient to adversarial interaction patterns**
- **Auditable and test-driven**

All core logic is enforced on-chain. Off-chain components (frontend, indexer, bots) are strictly optional and non-trusted.

---

## 🧠 High-Level Architecture

The protocol is composed of three main contracts.

```text
SingleWinnerDeployer
  |
  +--> LotterySingleWinner (multiple instances)
  |
  +--> LotteryRegistry
```

### Components

| Contract | Responsibility |
|--------|----------------|
| `SingleWinnerDeployer` | Factory responsible for deploying new lottery instances with validated parameters |
| `LotterySingleWinner` | A single raffle instance handling ticket sales, randomness, payouts, refunds, and accounting |
| `LotteryRegistry` | Canonical, append-only registry used for discovery and indexing |

---

## 🎟️ LotterySingleWinner

A `LotterySingleWinner` contract represents **one independent raffle** with exactly one winner.

### Core Features

- USDC-denominated tickets and prize pot
- Single winner selected via Pyth Entropy randomness
- Pull-based payouts (no forced transfers)
- Explicit accounting invariants
- Permissionless finalization
- Emergency recovery for stalled randomness
- Safe handling of malicious ERC20 and ETH receivers

### Lifecycle

1. **FundingPending**
   - Creator funds the prize pot in USDC
   - Deployer confirms funding

2. **Open**
   - Users buy tickets
   - Tickets are tracked using compressed ticket ranges
   - Accounting liabilities increase deterministically

3. **Drawing**
   - Anyone may finalize once conditions are met
   - Entropy randomness is requested
   - Governance actions are locked

4. **Completed**
   - Winner is selected on-chain
   - USDC liabilities are allocated:
     - Winner prize
     - Creator revenue
     - Protocol fees
   - Funds are withdrawn via pull-based claims

5. **Canceled**
   - Triggered if minimum tickets are not met
   - Or if randomness is stuck beyond a timeout
   - All participants can safely claim refunds

---

### 🔐 Accounting Model

The contract enforces **explicit solvency tracking**.

#### USDC
- `totalReservedUSDC` tracks all outstanding liabilities
- Includes:
  - Prize pot
  - Ticket revenue
  - Refunds
  - Protocol fees
- Withdrawals must reduce `totalReservedUSDC`
- Surplus USDC can only be swept after liabilities are covered

#### Native ETH
- Used only for entropy fees and refunds
- Failed ETH transfers are credited internally as `claimableNative`
- `totalClaimableNative` ensures ETH sweep safety

This design prevents:
- Insolvency
- Double withdrawals
- Admin fund extraction
- Silent accounting drift

---

### 🎲 Randomness (Pyth Entropy)

- Uses Pyth Entropy with asynchronous callbacks
- Each draw is bound to a specific entropy request ID
- Callbacks are validated against:
  - Entropy contract address
  - Provider address
  - Request sequence number
  - Correct lifecycle state

Invalid or replayed callbacks are ignored and cannot alter state.

If randomness stalls:
- Creator or owner may cancel after a short delay
- Anyone may cancel after a longer public delay

---

## 🏭 SingleWinnerDeployer

The deployer is a permissioned factory responsible for:

- Validating economic parameters:
  - Ticket price
  - Minimum batch sizes
  - Anti-spam constraints
  - Maximum caps
- Deploying lottery instances
- Transferring ownership to a designated `safeOwner`
- Registering lotteries in the registry

The deployer never holds user funds.

---

## 🗂️ LotteryRegistry

The registry is a non-custodial discovery layer:

- Tracks deployed lotteries
- Records creator and type metadata
- Supports pagination for indexers and frontends
- Cannot affect funds or lottery execution

The registry exists purely for transparency and discoverability.

---

## 🧪 Testing & Verification

The contracts in this repository are verified using an extensive **Foundry-based test suite**, including:

- Unit tests
- Integration tests
- Stateful invariant tests (fuzzing)

### 🔗 Test Repository

All tests live in a dedicated repository:

👉 https://github.com/NeoktaLabs/ppopgi-smartcontracts-foundry

That repository contains:
- Deterministic unit tests
- End-to-end lifecycle tests
- Adversarial edge-case coverage
- Invariant tests that prove global safety properties

---

### ✅ Properties Proven by Tests

The test suite demonstrates that:

- Funds are always solvent (`balance >= liabilities`)
- Claimable balances can never exceed reserved funds
- Randomness callbacks cannot be replayed or misbound
- Admin actions cannot steal user funds
- Emergency recovery paths always unblock users
- Registry integrity is preserved

Invariant testing further proves that these properties hold across thousands of randomized interaction sequences.

---

## ⚠️ Security Notes

- Contracts are designed to minimize trust and admin power
- All privileged actions are explicit, logged, and lifecycle-restricted
- Off-chain components are non-trusted
- The system remains unaudited

**Use only with funds you are comfortable risking until an independent audit is completed.**

---
