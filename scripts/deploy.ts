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
        { kind: "uups" }
    );

    await escrow.waitForDeployment();
    const proxyAddress = await escrow.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log("\n✅ Deployment successful!");
    console.log("  Proxy Address:", proxyAddress);
    console.log("  Implementation:", implAddress);

    // Save deployment info
    const deploymentInfo = {
        network: (await ethers.provider.getNetwork()).name,
        chainId: Number((await ethers.provider.getNetwork()).chainId),
        proxy: proxyAddress,
        implementation: implAddress,
        deployer: deployer.address,
        platformSigner,
        platformFund,
        timestamp: new Date().toISOString(),
    };

    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

    const filename = `${deploymentInfo.network || "local"}-${Date.now()}.json`;
    fs.writeFileSync(
        path.join(deploymentsDir, filename),
        JSON.stringify(deploymentInfo, null, 2)
    );
    console.log(`\n📄 Deployment saved to: deployments/${filename}`);

    // Update platform backend .env
    const platformEnv = path.join(__dirname, "../../platform/.env");
    if (fs.existsSync(platformEnv)) {
        let content = fs.readFileSync(platformEnv, "utf-8");
        if (content.includes("ESCROW_ADDRESS=")) {
            content = content.replace(
                /ESCROW_ADDRESS="?[^"\n]*"?/,
                `ESCROW_ADDRESS="${proxyAddress}"`
            );
        } else {
            content += `\nESCROW_ADDRESS="${proxyAddress}"\n`;
        }
        fs.writeFileSync(platformEnv, content);
        console.log("✅ platform/.env updated");
    }

    // Update app frontend .env.local
    const appEnvLocal = path.join(__dirname, "../../app/.env.local");
    const escrowLine = `NEXT_PUBLIC_ESCROW_ADDRESS="${proxyAddress}"`;
    if (fs.existsSync(appEnvLocal)) {
        let content = fs.readFileSync(appEnvLocal, "utf-8");
        if (content.includes("NEXT_PUBLIC_ESCROW_ADDRESS=")) {
            content = content.replace(
                /NEXT_PUBLIC_ESCROW_ADDRESS="?[^"\n]*"?/,
                escrowLine
            );
        } else {
            content += `\n${escrowLine}\n`;
        }
        fs.writeFileSync(appEnvLocal, content);
    } else {
        fs.writeFileSync(appEnvLocal, `${escrowLine}\n`);
    }
    console.log("✅ app/.env.local updated");

    console.log("\n═══════════════════════════════════════════════");
    console.log("  Done! Next steps:");
    console.log("  1. Verify: npx hardhat verify --network base-sepolia", proxyAddress);
    console.log("  2. Start backend: cd ../platform && pnpm dev");
    console.log("  3. Start frontend: cd ../app && pnpm dev");
    console.log("═══════════════════════════════════════════════");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
