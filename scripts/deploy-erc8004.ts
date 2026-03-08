import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";

const ERC8004_JSON = path.join(__dirname, "ERC8004.json");

interface ERC8004Addresses {
    identityProxy: string;
    identityImplementation: string;
    reputationProxy: string;
    reputationImplementation: string;
    network: string;
    chainId: number;
    deployer: string;
    updatedAt: string;
}

function saveERC8004Json(data: ERC8004Addresses) {
    fs.writeFileSync(ERC8004_JSON, JSON.stringify(data, null, 2));
    console.log("📄 scripts/ERC8004.json updated");
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === "unknown" ? "base-sepolia" : network.name;
    const balance = await ethers.provider.getBalance(deployer.address);

    console.log("═══════════════════════════════════════════════");
    console.log("  ClawPact ERC-8004 — Identity & Reputation");
    console.log("═══════════════════════════════════════════════");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("Network:", networkName, `(chainId: ${network.chainId})`);

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH — please fund the wallet first");
    }

    // ─── Deploy Identity Registry ──────────────────────────────
    const IdentityFactory = await ethers.getContractFactory("ClawPactIdentityRegistry");
    const existingIdentityProxy = process.env.IDENTITY_ADDRESS_PROXY;

    let identityProxyAddress: string;
    let identityImplAddress: string;

    if (existingIdentityProxy) {
        console.log("\n🔄 Upgrading Identity Registry...");
        const upgraded = await upgrades.upgradeProxy(existingIdentityProxy, IdentityFactory as any, { kind: "uups" });
        await upgraded.waitForDeployment();
        identityProxyAddress = existingIdentityProxy;
        identityImplAddress = await upgrades.erc1967.getImplementationAddress(identityProxyAddress);
        console.log("   ✅ Upgraded:", identityProxyAddress);
    } else {
        console.log("\n🆕 Deploying Identity Registry...");
        const identity = await upgrades.deployProxy(IdentityFactory as any, [deployer.address], { kind: "uups" });
        await identity.waitForDeployment();
        identityProxyAddress = await identity.getAddress();
        identityImplAddress = await upgrades.erc1967.getImplementationAddress(identityProxyAddress);
        console.log("   ✅ Deployed:", identityProxyAddress);
    }

    // ─── Deploy Reputation Registry ────────────────────────────
    const ReputationFactory = await ethers.getContractFactory("ClawPactReputationRegistry");
    const existingReputationProxy = process.env.REPUTATION_ADDRESS_PROXY;

    let reputationProxyAddress: string;
    let reputationImplAddress: string;

    if (existingReputationProxy) {
        console.log("\n🔄 Upgrading Reputation Registry...");
        const upgraded = await upgrades.upgradeProxy(existingReputationProxy, ReputationFactory as any, { kind: "uups" });
        await upgraded.waitForDeployment();
        reputationProxyAddress = existingReputationProxy;
        reputationImplAddress = await upgrades.erc1967.getImplementationAddress(reputationProxyAddress);
        console.log("   ✅ Upgraded:", reputationProxyAddress);
    } else {
        console.log("\n🆕 Deploying Reputation Registry...");
        const reputation = await upgrades.deployProxy(ReputationFactory as any, [deployer.address, identityProxyAddress], { kind: "uups" });
        await reputation.waitForDeployment();
        reputationProxyAddress = await reputation.getAddress();
        reputationImplAddress = await upgrades.erc1967.getImplementationAddress(reputationProxyAddress);
        console.log("   ✅ Deployed:", reputationProxyAddress);
    }

    // ─── Optional: Link Reputation to Escrow & TipJar ──────────
    const escrowProxy = process.env.ESCROW_ADDRESS_PROXY;
    const tipJarProxy = process.env.TIPJAR_ADDRESS_PROXY;

    if (escrowProxy) {
        console.log("\n⏳ Linking Reputation Registry to Escrow...");
        const escrowContract = await ethers.getContractAt("ClawPactEscrowV2", escrowProxy) as any;
        await escrowContract.setReputationRegistry(reputationProxyAddress);
        console.log("   🔗 Escrow linked to Reputation Registry");
    }

    if (tipJarProxy) {
        console.log("⏳ Linking Reputation Registry to TipJar...");
        const tipJarContract = await ethers.getContractAt("ClawPactTipJar", tipJarProxy) as any;
        await tipJarContract.setReputationRegistry(reputationProxyAddress);
        console.log("   🔗 TipJar linked to Reputation Registry");
    }

    // ─── Save ERC8004.json ──────────────────────────────────────
    saveERC8004Json({
        identityProxy: identityProxyAddress,
        identityImplementation: identityImplAddress,
        reputationProxy: reputationProxyAddress,
        reputationImplementation: reputationImplAddress,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        updatedAt: new Date().toISOString(),
    });

    console.log("\n═══════════════════════════════════════════════");
    console.log("  ERC-8004 deployment complete!");
    console.log("  Identity Proxy:", identityProxyAddress);
    console.log("  Reputation Proxy:", reputationProxyAddress);
    if (!escrowProxy && !tipJarProxy) {
        console.log("\n  ⚠️  No ESCROW_ADDRESS_PROXY / TIPJAR_ADDRESS_PROXY set.");
        console.log("  To link, set env vars and re-run, or call setReputationRegistry() manually.");
    }
    console.log("═══════════════════════════════════════════════");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
