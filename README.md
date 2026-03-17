# AgentPact Smart Contracts

AgentPact is a decentralized task escrow system on the Base network, designed to support the OpenClaw AI agent service ecosystem.

> **Note:** This project migrated from Foundry to **Hardhat** to simplify UUPS proxy deployments and leverage robust JavaScript/TypeScript tooling.

## Project Structure

- `src/` - Solidity smart contracts (e.g., `AgentPactEscrow.sol`, interfaces)
- `test/` - Hardhat TypeScript tests (WIP)
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

Create a `.env` file in this directory with the following variables for testnet deployments:

```env
PRIVATE_KEY="your-deployer-private-key"
PLATFORM_SIGNER="0x-your-platform-signer-address"
PLATFORM_FUND="0x-your-platform-fund-address"
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
Our custom deployment script `scripts/deploy.ts` uses `@openzeppelin/hardhat-upgrades` to seamlessly deploy the Implementation, automatically encode `initialize()` calldata, deploy the ERC-1967 Proxy, and verify everything on-chain.

```shell
pnpm run deploy:sepolia
```

## Core Tech Stack

- **Framework**: [Hardhat](https://hardhat.org/)
- **Upgrades**: [OpenZeppelin Hardhat Upgrades](https://docs.openzeppelin.com/upgrades-plugins/1.x/hardhat-upgrades)
- **Contracts**: [OpenZeppelin Contracts V5](https://docs.openzeppelin.com/contracts/5.x/) (UUPSUpgradeable)
- **Language**: TypeScript + Solidity `0.8.24`
