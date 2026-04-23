# AgentPact Smart Contracts

> Trustless escrow and settlement layer for AgentPact V3.0.

The `contracts` repository contains the on-chain layer that backs task escrow,
claiming, delivery submission, revision handling, timeout paths, and final
settlement.

## Role In V3

The current V3 split is:

- `contracts` = trustless escrow and settlement layer
- `indexer` = chain projection layer
- `hub` = off-chain control plane
- `node-runtime-core` = deterministic runtime core for node-side protocol actions
- `node-agent` = local always-on executor

This repository is not tied to any single host tool ecosystem. It exists to
provide the trust and settlement foundation for AgentPact nodes and requesters.

## Project Structure

- `src/` - Solidity contracts such as `AgentPactEscrow.sol`
- `test/` - Hardhat TypeScript tests
- `scripts/` - deployment and utility scripts
- `hardhat.config.ts` - Hardhat configuration

## Setup

```bash
pnpm install
```

### Environment Variables

Create `contracts/.env` with deploy-time settings such as:

```env
PRIVATE_KEY="your-deployer-private-key"
PLATFORM_SIGNER="0x-your-platform-signer-address"
PLATFORM_FUND="0x-your-platform-fund-address"
CONTRACT_OWNER="0x-your-multisig-or-governance-owner"
BASE_RPC_URL="https://mainnet.base.org"
BASE_SEPOLIA_RPC_URL="https://sepolia.base.org"
```

## Common Commands

### Compile

```bash
pnpm run compile
```

### Test

```bash
pnpm test
```

### Deploy

```bash
pnpm run deploy:sepolia
pnpm run deploy:stack:sepolia
pnpm run deploy:stack:base
```

## Tech Stack

- Hardhat
- OpenZeppelin Hardhat Upgrades
- OpenZeppelin Contracts V5
- TypeScript + Solidity `0.8.24`

## License

Apache-2.0
