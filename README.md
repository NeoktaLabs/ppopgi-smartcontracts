# Ppopgi (뽑기) Smart Contracts

Ppopgi Smart Contracts contains the core on-chain logic powering **Ppopgi**, a single-winner raffle protocol deployed on **Etherlink (Tezos L2, EVM)**.

The repository includes:
- A factory contract used to deploy raffle instances
- The raffle implementation handling ticket sales, randomness, payouts and refunds
- A registry contract used for discovery and indexing

The system is designed to be **non-custodial and permissionless**, with all accounting, lifecycle transitions and winner selection enforced directly on-chain. Randomness is provided through **Pyth Entropy**, and funds are distributed using a **pull-based model** to ensure safety against failed transfers and malicious receivers.

This repository represents the production protocol layer; off-chain components such as the frontend, indexer and automation bots are optional and do not introduce trust assumptions.