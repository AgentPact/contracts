import fs from "fs";
import path from "path";
import dotenv from "dotenv";

export const CONTRACTS_ENV_PATH = path.join(__dirname, "../.env");

let cachedContractsEnv: Record<string, string> | undefined;

export function readContractsEnvFile(): Record<string, string> {
    if (cachedContractsEnv) {
        return cachedContractsEnv;
    }

    if (!fs.existsSync(CONTRACTS_ENV_PATH)) {
        cachedContractsEnv = {};
        return cachedContractsEnv;
    }

    cachedContractsEnv = dotenv.parse(
        fs.readFileSync(CONTRACTS_ENV_PATH, "utf8")
    );
    return cachedContractsEnv;
}

export function readContractsEnvValue(...keys: string[]): string | undefined {
    const env = readContractsEnvFile();

    for (const key of keys) {
        const value = env[key]?.trim();
        if (value) {
            return value;
        }
    }

    return undefined;
}

export function readContractsEnvFlag(key: string): boolean {
    return readContractsEnvValue(key) === "true";
}
