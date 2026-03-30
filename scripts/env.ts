import fs from "fs";
import path from "path";
import { ethers } from "hardhat";
import {
    readContractsEnvValue,
} from "./contracts-env";

export type SupportedNetworkName = "base" | "base-sepolia";
export interface BuybackConfig {
    enabled: boolean;
    buybackBps: number;
    buybackToken: string;
    poolFee: number;
    maxSlippageBps: number;
}

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

export const ESCROW_JSON_PATH = path.join(__dirname, "./ESCROW.json");

function normalizeAddress(value: string, label: string): string {
    try {
        return ethers.getAddress(value.trim());
    } catch {
        throw new Error(`Invalid ${label}: ${value}`);
    }
}

function resolveAddressFromEnv(keys: string[]): string | undefined {
    const value = readContractsEnvValue(...keys);
    if (value) {
        return normalizeAddress(value, keys.join(" / "));
    }

    return undefined;
}

function parseBooleanEnv(
    key: string,
    defaultValue?: boolean
): boolean | undefined {
    const value = readContractsEnvValue(key);
    if (value === undefined) {
        return defaultValue;
    }
    if (value === "true") {
        return true;
    }
    if (value === "false") {
        return false;
    }

    throw new Error(`Invalid ${key}: expected "true" or "false", received ${value}`);
}

function parseIntegerEnv(
    key: string,
    options: {
        defaultValue?: number;
        min?: number;
        max?: number;
    } = {}
): number | undefined {
    const raw = readContractsEnvValue(key);
    if (raw === undefined) {
        return options.defaultValue;
    }

    if (!/^\d+$/.test(raw)) {
        throw new Error(`Invalid ${key}: expected an integer, received ${raw}`);
    }

    const value = Number(raw);
    if (!Number.isSafeInteger(value)) {
        throw new Error(`Invalid ${key}: integer is out of range`);
    }
    if (options.min !== undefined && value < options.min) {
        throw new Error(`Invalid ${key}: expected >= ${options.min}, received ${value}`);
    }
    if (options.max !== undefined && value > options.max) {
        throw new Error(`Invalid ${key}: expected <= ${options.max}, received ${value}`);
    }

    return value;
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
    const defaults = NETWORK_DEFAULTS[normalizeNetworkName(networkName)];

    return normalizeAddress(
        readContractsEnvValue("USDC_ADDRESS") || defaults.usdc,
        "USDC_ADDRESS"
    );
}

export function resolveWethAddress(networkName?: string): string {
    return normalizeAddress(
        readContractsEnvValue("WETH_ADDRESS") ||
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

export function resolveBuybackConfig(): BuybackConfig | undefined {
    const hasAnyBuybackSetting = [
        "BUYBACK_ENABLED",
        "BUYBACK_BPS",
        "BUYBACK_TOKEN",
        "SWAP_POOL_FEE",
        "MAX_SLIPPAGE_BPS",
    ].some((key) => readContractsEnvValue(key) !== undefined);

    if (!hasAnyBuybackSetting) {
        return undefined;
    }

    const buybackToken = resolveAddressFromEnv(["BUYBACK_TOKEN"]);
    if (!buybackToken) {
        throw new Error(
            "Missing BUYBACK_TOKEN while buyback config vars are set."
        );
    }

    return {
        enabled: parseBooleanEnv("BUYBACK_ENABLED", false) ?? false,
        buybackBps:
            parseIntegerEnv("BUYBACK_BPS", {
                defaultValue: 5000,
                min: 0,
                max: 10_000,
            }) ?? 5000,
        buybackToken,
        poolFee:
            parseIntegerEnv("SWAP_POOL_FEE", {
                defaultValue: 3000,
                min: 0,
                max: 16_777_215,
            }) ?? 3000,
        maxSlippageBps:
            parseIntegerEnv("MAX_SLIPPAGE_BPS", {
                defaultValue: 500,
                min: 0,
                max: 2_000,
            }) ?? 500,
    };
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
