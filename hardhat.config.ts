import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import { readContractsEnvValue } from "./scripts/contracts-env";

function resolveAccounts(): string[] {
    const privateKey = readContractsEnvValue("PRIVATE_KEY");
    if (!privateKey) {
        return [];
    }

    return [privateKey.startsWith("0x") ? privateKey : `0x${privateKey}`];
}

const config: HardhatUserConfig = {
    solidity: {
        version: "0.8.24",
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
            viaIR: true,
            evmVersion: "cancun",
        },
    },
    paths: {
        sources: "./src",
        tests: "./test",
        cache: "./cache",
        artifacts: "./artifacts",
    },
    networks: {
        base: {
            url:
                readContractsEnvValue("BASE_RPC_URL") ||
                "https://mainnet.base.org",
            chainId: 8453,
            accounts: resolveAccounts(),
        },
        "base-sepolia": {
            url:
                readContractsEnvValue("BASE_SEPOLIA_RPC_URL") ||
                "https://sepolia.base.org",
            chainId: 84532,
            accounts: resolveAccounts(),
        },
    },
    etherscan: {
        apiKey: {
            base: readContractsEnvValue("BASESCAN_API_KEY") || "",
            baseSepolia: readContractsEnvValue("BASESCAN_API_KEY") || "",
        },
    },
};

export default config;
