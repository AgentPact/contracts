import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("═══════════════════════════════════════════════");
    console.log("  ClawPact Escrow V2 — UUPS Proxy Deployment");
    console.log("═══════════════════════════════════════════════");
    console.log("Deployer:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH — please fund the wallet first");
    }

    // Configuration
    const platformSigner =
        process.env.PLATFORM_SIGNER || deployer.address;
    const platformFund =
        process.env.PLATFORM_FUND || deployer.address;
    const initialOwner = deployer.address;

    console.log("\nConfiguration:");
    console.log("  Platform Signer:", platformSigner);
    console.log("  Platform Fund:", platformFund);
    console.log("  Initial Owner:", initialOwner);

    // Deploy
    const EscrowFactory = await ethers.getContractFactory("ClawPactEscrowV2");

    console.log("\n⏳ Deploying ClawPactEscrowV2 as UUPS Proxy...");
    const escrow = await upgrades.deployProxy(
        EscrowFactory,
        [platformSigner, platformFund, initialOwner],
        {
            kind: "uups",
            // OZ v5: ReentrancyGuard uses transient storage (no constructor state)
            // Safe for UUPS but plugin still flags it
            unsafeAllow: ["constructor", "state-variable-immutable"],
        }
    );

    await escrow.waitForDeployment();
    const proxyAddress = await escrow.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log("\n✅ Deployment successful!");
    console.log("  Proxy Address:", proxyAddress);
    console.log("  Implementation:", implAddress);

    // ─── Save deployment record ──────────────────────────────────
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === "unknown" ? "base-sepolia" : network.name;

    const deploymentInfo = {
        network: networkName,
        chainId: Number(network.chainId),
        proxy: proxyAddress,
        implementation: implAddress,
        deployer: deployer.address,
        platformSigner,
        platformFund,
        timestamp: new Date().toISOString(),
    };

    // Save to deployments/ directory
    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

    const filename = `${networkName}-${Date.now()}.json`;
    fs.writeFileSync(
        path.join(deploymentsDir, filename),
        JSON.stringify(deploymentInfo, null, 2)
    );
    console.log(`\n📄 Deployment saved: deployments/${filename}`);

    // Also maintain a latest-addresses.json for easy lookup
    const latestPath = path.join(deploymentsDir, "latest-addresses.json");
    let latestAddresses: Record<string, any> = {};
    if (fs.existsSync(latestPath)) {
        latestAddresses = JSON.parse(fs.readFileSync(latestPath, "utf-8"));
    }
    latestAddresses[networkName] = {
        proxy: proxyAddress,
        implementation: implAddress,
        deployedAt: deploymentInfo.timestamp,
    };
    fs.writeFileSync(latestPath, JSON.stringify(latestAddresses, null, 2));
    console.log("📄 Updated: deployments/latest-addresses.json");

    // ─── Update env files ────────────────────────────────────────
    // platform/.env
    const platformEnv = path.join(__dirname, "../../platform/.env");
    updateEnvFile(platformEnv, "ESCROW_ADDRESS", proxyAddress);

    // app/.env.local
    const appEnvLocal = path.join(__dirname, "../../app/.env.local");
    updateEnvFile(appEnvLocal, "NEXT_PUBLIC_ESCROW_ADDRESS", proxyAddress);

    console.log("\n═══════════════════════════════════════════════");
    console.log("  ✅ All done! Next steps:");
    console.log(`  1. Verify: npx hardhat verify --network ${networkName} ${proxyAddress}`);
    console.log("  2. Start backend:  cd ../platform && pnpm dev");
    console.log("  3. Start frontend: cd ../app && pnpm dev");
    console.log("═══════════════════════════════════════════════");
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
    console.log(`✅ ${path.basename(envPath)} → ${key} updated`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
