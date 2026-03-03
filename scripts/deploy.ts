import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";

const ESCROW_JSON = path.join(__dirname, "ESCROW.json");

interface EscrowAddresses {
    proxy: string;
    implementation: string;
    network: string;
    chainId: number;
    deployer: string;
    updatedAt: string;
}

function saveEscrowJson(data: EscrowAddresses) {
    fs.writeFileSync(ESCROW_JSON, JSON.stringify(data, null, 2));
    console.log("📄 scripts/ESCROW.json updated");
}

function updateEnvFile(envPath: string, key: string, value: string) {
    const line = `${key}="${value}"`;
    if (fs.existsSync(envPath)) {
        let content = fs.readFileSync(envPath, "utf-8");
        const regex = new RegExp(`${key}="?[^"\\n]*"?`);
        if (regex.test(content)) {
            content = content.replace(regex, line);
        } else {
            content += `\n${line}\n`;
        }
        fs.writeFileSync(envPath, content);
    } else {
        fs.writeFileSync(envPath, `${line}\n`);
    }
    console.log(`✅ ${path.basename(envPath)} → ${key}`);
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === "unknown" ? "base-sepolia" : network.name;
    const balance = await ethers.provider.getBalance(deployer.address);

    console.log("═══════════════════════════════════════════════");
    console.log("  ClawPact Escrow V2 — Deployment");
    console.log("═══════════════════════════════════════════════");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("Network:", networkName, `(chainId: ${network.chainId})`);

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH — please fund the wallet first");
    }

    const EscrowFactory = await ethers.getContractFactory("ClawPactEscrowV2");

    const existingProxy = process.env.ESCROW_ADDRESS_PROXY;

    let proxyAddress: string;
    let implAddress: string;

    if (existingProxy) {
        // ─── Upgrade Mode ──────────────────────────────────────────
        console.log("\n🔄 Upgrade mode — proxy already deployed");
        console.log("   Existing Proxy:", existingProxy);

        const oldImpl = await upgrades.erc1967.getImplementationAddress(existingProxy);
        console.log("   Old Implementation:", oldImpl);

        console.log("\n⏳ Deploying new implementation & upgrading proxy...");
        const upgraded = await upgrades.upgradeProxy(existingProxy, EscrowFactory, {
            kind: "uups",
            unsafeAllow: ["constructor", "state-variable-immutable"],
        });
        await upgraded.waitForDeployment();

        proxyAddress = existingProxy;
        implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

        console.log("\n✅ Upgrade successful!");
        console.log("   Proxy (unchanged):", proxyAddress);
        console.log("   New Implementation:", implAddress);
    } else {
        // ─── Fresh Deploy Mode ─────────────────────────────────────
        console.log("\n🆕 Fresh deploy mode — no existing proxy found");

        const platformSigner = process.env.PLATFORM_SIGNER || deployer.address;
        const platformFund = process.env.PLATFORM_FUND || deployer.address;

        console.log("   Platform Signer:", platformSigner);
        console.log("   Platform Fund:", platformFund);
        console.log("   Initial Owner:", deployer.address);

        console.log("\n⏳ Deploying UUPS Proxy + Implementation...");
        const escrow = await upgrades.deployProxy(
            EscrowFactory,
            [platformSigner, platformFund, deployer.address],
            {
                kind: "uups",
                unsafeAllow: ["constructor", "state-variable-immutable"],
            }
        );
        await escrow.waitForDeployment();

        proxyAddress = await escrow.getAddress();
        implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

        console.log("\n✅ Fresh deploy successful!");
        console.log("   Proxy:", proxyAddress);
        console.log("   Implementation:", implAddress);
    }

    // ─── Save ESCROW.json ────────────────────────────────────────
    saveEscrowJson({
        proxy: proxyAddress,
        implementation: implAddress,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        updatedAt: new Date().toISOString(),
    });

    // ─── Update env files ────────────────────────────────────────
    updateEnvFile(
        path.join(__dirname, "../../platform/.env"),
        "ESCROW_ADDRESS",
        proxyAddress
    );
    updateEnvFile(
        path.join(__dirname, "../../app/.env.local"),
        "NEXT_PUBLIC_ESCROW_ADDRESS",
        proxyAddress
    );

    console.log("\n═══════════════════════════════════════════════");
    console.log("  Done! Verify:");
    console.log(`  npx hardhat verify --network ${networkName} ${proxyAddress}`);
    console.log("═══════════════════════════════════════════════");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
