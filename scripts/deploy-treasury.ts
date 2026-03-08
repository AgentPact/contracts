import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";

const TREASURY_JSON = path.join(__dirname, "TREASURY.json");

interface TreasuryAddresses {
    treasuryProxy: string;
    treasuryImplementation: string;
    network: string;
    chainId: number;
    deployer: string;
    updatedAt: string;
}

function saveTreasuryJson(data: TreasuryAddresses) {
    fs.writeFileSync(TREASURY_JSON, JSON.stringify(data, null, 2));
    console.log("📄 scripts/TREASURY.json updated");
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === "unknown" ? "base-sepolia" : network.name;
    const balance = await ethers.provider.getBalance(deployer.address);

    console.log("═══════════════════════════════════════════════");
    console.log("  ClawPact Treasury — Deployment");
    console.log("═══════════════════════════════════════════════");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("Network:", networkName, `(chainId: ${network.chainId})`);

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH — please fund the wallet first");
    }

    const platformWallet = process.env.PLATFORM_FUND || deployer.address;
    // WETH on Base: 0x4200000000000000000000000000000000000006
    // WETH on Base Sepolia: same address (canonical WETH)
    const wethAddress = process.env.WETH_ADDRESS || "0x4200000000000000000000000000000000000006";

    console.log("   Platform Wallet:", platformWallet);
    console.log("   WETH:", wethAddress);

    // ─── Deploy Treasury ───────────────────────────────────────
    const TreasuryFactory = await ethers.getContractFactory("ClawPactTreasury");
    const existingProxy = process.env.TREASURY_ADDRESS_PROXY;

    let treasuryProxyAddress: string;
    let treasuryImplAddress: string;

    if (existingProxy) {
        console.log("\n🔄 Upgrading Treasury...");
        const upgraded = await upgrades.upgradeProxy(existingProxy, TreasuryFactory as any, {
            kind: "uups",
            unsafeAllow: ["constructor"],
        });
        await upgraded.waitForDeployment();
        treasuryProxyAddress = existingProxy;
        treasuryImplAddress = await upgrades.erc1967.getImplementationAddress(treasuryProxyAddress);
        console.log("   ✅ Upgraded:", treasuryProxyAddress);
    } else {
        console.log("\n🆕 Deploying Treasury...");
        const treasury = await upgrades.deployProxy(
            TreasuryFactory as any,
            [platformWallet, wethAddress, deployer.address],
            {
                kind: "uups",
                unsafeAllow: ["constructor"],
            }
        );
        await treasury.waitForDeployment();
        treasuryProxyAddress = await treasury.getAddress();
        treasuryImplAddress = await upgrades.erc1967.getImplementationAddress(treasuryProxyAddress);
        console.log("   ✅ Deployed:", treasuryProxyAddress);
    }

    // ─── Authorize Escrow & TipJar as callers ──────────────────
    const treasury = await ethers.getContractAt("ClawPactTreasury", treasuryProxyAddress) as any;

    const escrowProxy = process.env.ESCROW_ADDRESS_PROXY;
    const tipJarProxy = process.env.TIPJAR_ADDRESS_PROXY;

    if (escrowProxy) {
        console.log("\n⏳ Authorizing Escrow as Treasury caller...");
        await treasury.setAuthorizedCaller(escrowProxy, true);
        console.log("   🔗 Escrow authorized");

        console.log("⏳ Setting Treasury on Escrow...");
        const escrow = await ethers.getContractAt("ClawPactEscrowV2", escrowProxy) as any;
        await escrow.setTreasury(treasuryProxyAddress);
        console.log("   🔗 Escrow → Treasury linked");
    }

    if (tipJarProxy) {
        console.log("\n⏳ Authorizing TipJar as Treasury caller...");
        await treasury.setAuthorizedCaller(tipJarProxy, true);
        console.log("   🔗 TipJar authorized");

        console.log("⏳ Setting Treasury on TipJar...");
        const tipJar = await ethers.getContractAt("ClawPactTipJar", tipJarProxy) as any;
        await tipJar.setTreasuryContract(treasuryProxyAddress);
        console.log("   🔗 TipJar → Treasury linked");
    }

    // ─── Optional: Configure Uniswap Buyback ───────────────────
    const swapRouterAddr = process.env.SWAP_ROUTER;
    if (swapRouterAddr) {
        console.log("\n⏳ Configuring Uniswap SwapRouter...");
        await treasury.setSwapRouter(swapRouterAddr);
        console.log("   🔗 SwapRouter:", swapRouterAddr);
    }

    // ─── Save TREASURY.json ─────────────────────────────────────
    saveTreasuryJson({
        treasuryProxy: treasuryProxyAddress,
        treasuryImplementation: treasuryImplAddress,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        updatedAt: new Date().toISOString(),
    });

    console.log("\n═══════════════════════════════════════════════");
    console.log("  Treasury deployment complete!");
    console.log("  Proxy:", treasuryProxyAddress);
    console.log("  Buyback: DISABLED (default)");
    console.log("");
    console.log("  To enable buyback, call:");
    console.log("  treasury.setBuybackConfig(true, 5000, <TOKEN>, 3000, 500)");
    if (!escrowProxy || !tipJarProxy) {
        console.log("\n  ⚠️  Set ESCROW_ADDRESS_PROXY and TIPJAR_ADDRESS_PROXY to auto-link.");
    }
    console.log("═══════════════════════════════════════════════");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
