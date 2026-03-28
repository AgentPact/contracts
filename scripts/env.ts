import fs from "fs";
import path from "path";
import dotenv from "dotenv";
import { ethers } from "hardhat";

export type SupportedNetworkName = "base" | "base-sepolia";

export const NETWORK_DEFAULTS: Record<
    SupportedNetworkName,
    {
        chainId: number;
        rpcUrl: string;
        usdc: string;
        weth: string;
    }
> = {
    base: {
        chainId: 8453,
        rpcUrl: "https://mainnet.base.org",
        usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        weth: "0x4200000000000000000000000000000000000006",
    },
    "base-sepolia": {
        chainId: 84532,
        rpcUrl: "https://sepolia.base.org",
        usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        weth: "0x4200000000000000000000000000000000000006",
    },
};

export const APP_ENV_PATH = path.join(__dirname, "../../app/.env");
export const PLATFORM_ENV_PATH = path.join(__dirname, "../../platform/.env");
export const ESCROW_JSON_PATH = path.join(__dirname, "./ESCROW.json");

function readEnvFile(filePath: string): Record<string, string> {
    if (!fs.existsSync(filePath)) {
        return {};
    }

    return dotenv.parse(fs.readFileSync(filePath, "utf8"));
}

function normalizeAddress(value: string, label: string): string {
    try {
        return ethers.getAddress(value.trim());
    } catch {
        throw new Error(`Invalid ${label}: ${value}`);
    }
}

function resolveAddressFromEnv(keys: string[]): string | undefined {
    for (const key of keys) {
        const value = process.env[key]?.trim();
        if (value) {
            return normalizeAddress(value, key);
        }
    }

    return undefined;
}

export function normalizeNetworkName(
    networkName?: string | null,
    chainId?: bigint | number
): SupportedNetworkName {
    if (networkName === "base" || chainId === 8453 || chainId === 8453n) {
        return "base";
    }

    return "base-sepolia";
}

export function isProductionNetwork(networkName?: string | null): boolean {
    return normalizeNetworkName(networkName) === "base";
}

export function resolveUsdcAddress(networkName?: string): string {
    const appEnv = readEnvFile(APP_ENV_PATH);
    const platformEnv = readEnvFile(PLATFORM_ENV_PATH);
    const defaults = NETWORK_DEFAULTS[normalizeNetworkName(networkName)];

    return normalizeAddress(
        appEnv.USDC_ADDRESS?.trim() ||
            process.env.USDC_ADDRESS?.trim() ||
            platformEnv.USDC_ADDRESS?.trim() ||
            defaults.usdc,
        "USDC_ADDRESS"
    );
}

export function resolveWethAddress(networkName?: string): string {
    return normalizeAddress(
        process.env.WETH_ADDRESS?.trim() ||
            NETWORK_DEFAULTS[normalizeNetworkName(networkName)].weth,
        "WETH_ADDRESS"
    );
}

export function resolveContractOwner(
    networkName: string,
    deployerAddress: string
): string {
    const owner = resolveAddressFromEnv([
        "CONTRACT_OWNER",
        "GOVERNANCE_OWNER",
        "OWNER_ADDRESS",
    ]);

    if (owner) {
        return owner;
    }

    if (isProductionNetwork(networkName)) {
        throw new Error(
            "Missing CONTRACT_OWNER (or GOVERNANCE_OWNER / OWNER_ADDRESS) for Base mainnet deployment."
        );
    }

    return normalizeAddress(deployerAddress, "deployer address");
}

export function resolvePlatformSignerAddress(
    networkName: string,
    deployerAddress: string
): string {
    const signer = resolveAddressFromEnv(["PLATFORM_SIGNER"]);
    if (signer) {
        return signer;
    }

    if (isProductionNetwork(networkName)) {
        throw new Error(
            "Missing PLATFORM_SIGNER for Base mainnet deployment."
        );
    }

    return normalizeAddress(deployerAddress, "deployer address");
}

export function resolvePlatformFundAddress(
    networkName: string,
    deployerAddress: string
): string {
    const fund = resolveAddressFromEnv(["PLATFORM_FUND", "PLATFORM_WALLET"]);
    if (fund) {
        return fund;
    }

    if (isProductionNetwork(networkName)) {
        throw new Error(
            "Missing PLATFORM_FUND (or PLATFORM_WALLET) for Base mainnet deployment."
        );
    }

    return normalizeAddress(deployerAddress, "deployer address");
}

export function resolveSwapRouterAddress(): string | undefined {
    return resolveAddressFromEnv(["SWAP_ROUTER"]);
}

export function resolveSwapQuoterAddress(): string | undefined {
    return resolveAddressFromEnv(["SWAP_QUOTER"]);
}

export function readEscrowJson(): {
    escrowProxy?: string;
    tipJarProxy?: string;
} {
    if (!fs.existsSync(ESCROW_JSON_PATH)) {
        return {};
    }

    try {
        return JSON.parse(fs.readFileSync(ESCROW_JSON_PATH, "utf8")) as {
            escrowProxy?: string;
            tipJarProxy?: string;
        };
    } catch {
        return {};
    }
}
