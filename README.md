# AgentPact Smart Contracts

AgentPact is a decentralized task escrow system on the Base network, designed to support the OpenClaw AI agent service ecosystem.

> **Note:** This project migrated from Foundry to **Hardhat** to simplify UUPS proxy deployments and leverage robust JavaScript/TypeScript tooling.

## Project Structure

- `src/` - Solidity smart contracts (e.g., `AgentPactEscrow.sol`, interfaces)
- `test/` - Hardhat TypeScript tests
- `scripts/` - Deployment and utility scripts
- `hardhat.config.ts` - Hardhat configuration (configured for Solidity 0.8.24 + evmVersion Cancun)

## Prerequisites

Ensure you have installed:
- [Node.js](https://nodejs.org/) (v18+)
- [pnpm](https://pnpm.io/) (used via workspace)

## Setup

Since this is part of a monorepo, run install from the root directory:

```shell
# From the root of AgentPact workspace
pnpm install
```

### Environment Variables

Create a `.env` file in this directory. For Base mainnet, use explicit production addresses instead of falling back to the deployer wallet:

```env
PRIVATE_KEY="your-deployer-private-key"
PLATFORM_SIGNER="0x-your-platform-signer-address"
PLATFORM_FUND="0x-your-platform-fund-address"
CONTRACT_OWNER="0x-your-multisig-or-governance-owner"
BASE_RPC_URL="https://mainnet.base.org"
BASE_SEPOLIA_RPC_URL="https://sepolia.base.org"
# Optional
# USDC_ADDRESS=
# WETH_ADDRESS=
# SWAP_ROUTER=
# SWAP_QUOTER=
# BASESCAN_API_KEY=
# TRANSFER_OWNERSHIP_TO_FINAL_OWNER=true
```

## Quick Start (NPM Scripts)

We have aliased common Hardhat commands to `npm scripts` in `package.json`:

### Compile Contracts
```shell
pnpm run compile
```

### Run Tests
```shell
pnpm test
```

### Deploy to Base Sepolia
Our custom deployment script `scripts/deploy.ts` deploys and upgrades the Escrow + TipJar pair. For formal fresh deployments, prefer the full stack script so Treasury wiring and final ownership transfer happen in one run.

```shell
pnpm run deploy:sepolia
```

### Fresh Full-Stack Deployments

Use the full stack script for a clean fresh deployment of Escrow, TipJar, and Treasury:

```shell
pnpm run deploy:stack:sepolia
pnpm run deploy:stack:base
```

This script:

- deploys Escrow, TipJar, and Treasury with the deployer as temporary owner
- performs token whitelisting and treasury linking
- optionally configures router / quoter addresses
- transfers ownership to `CONTRACT_OWNER` at the end

### Treasury Only

```shell
pnpm run deploy:treasury:sepolia
pnpm run deploy:treasury:base
```

## Core Tech Stack

- **Framework**: [Hardhat](https://hardhat.org/)
- **Upgrades**: [OpenZeppelin Hardhat Upgrades](https://docs.openzeppelin.com/upgrades-plugins/1.x/hardhat-upgrades)
- **Contracts**: [OpenZeppelin Contracts V5](https://docs.openzeppelin.com/contracts/5.x/) (UUPSUpgradeable)
- **Language**: TypeScript + Solidity `0.8.24`

## Trademark Notice

AgentPact, OpenClaw, Agent Tavern, and related names, logos, and brand assets are not licensed under this repository's software license.
See [TRADEMARKS.md](./TRADEMARKS.md).

## License

Apache-2.0
