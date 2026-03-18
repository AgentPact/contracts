import fs from "fs";
import path from "path";
import dotenv from "dotenv";

export const DEFAULT_BASE_SEPOLIA_USDC =
    "0x6C5816531C18aD328ffAc27B1E58EEB67528E429";

export const APP_ENV_PATH = path.join(__dirname, "../../app/.env");
export const PLATFORM_ENV_PATH = path.join(__dirname, "../../platform/.env");
export const ESCROW_JSON_PATH = path.join(__dirname, "./ESCROW.json");

function readEnvFile(filePath: string): Record<string, string> {
    if (!fs.existsSync(filePath)) {
        return {};
    }

    return dotenv.parse(fs.readFileSync(filePath, "utf8"));
}

export function resolveUsdcAddress(): string {
    const appEnv = readEnvFile(APP_ENV_PATH);
    const platformEnv = readEnvFile(PLATFORM_ENV_PATH);

    return (
        appEnv.USDC_ADDRESS?.trim() ||
        process.env.USDC_ADDRESS?.trim() ||
        platformEnv.USDC_ADDRESS?.trim() ||
        DEFAULT_BASE_SEPOLIA_USDC
    );
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

