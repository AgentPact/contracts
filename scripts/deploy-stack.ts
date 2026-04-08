import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";
import { readContractsEnvValue } from "./contracts-env";
import {
    normalizeNetworkName,
    resolveBuybackConfig,
    resolveContractOwner,
    resolvePlatformFundAddress,
    resolvePlatformSignerAddress,
    resolveSwapQuoterAddress,
    resolveSwapRouterAddress,
    resolveUsdcAddress,
    resolveWethAddress,
} from "./env";
import { waitForProxyImplementationAddress } from "./deploy-helpers";

const ESCROW_JSON = path.join(__dirname, "ESCROW.json");
const TREASURY_JSON = path.join(__dirname, "TREASURY.json");

function writeJson(filePath: string, data: unknown) {
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
    console.log(`${path.basename(filePath)} updated`);
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = normalizeNetworkName(network.name, network.chainId);
    const balance = await ethers.provider.getBalance(deployer.address);

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH - please fund the wallet first");
    }

    if (
        readContractsEnvValue("ESCROW_ADDRESS_PROXY") ||
        readContractsEnvValue("TIPJAR_ADDRESS_PROXY") ||
        readContractsEnvValue("TREASURY_ADDRESS_PROXY")
    ) {
        throw new Error(
            "deploy-stack.ts is intended for fresh deployments. Remove existing proxy env vars first."
        );
    }

    const finalOwner = resolveContractOwner(networkName, deployer.address);
    const platformSigner = resolvePlatformSignerAddress(
        networkName,
        deployer.address
    );
    const platformFund = resolvePlatformFundAddress(
        networkName,
        deployer.address
    );
    const usdcAddress = resolveUsdcAddress(networkName);
    const wethAddress = resolveWethAddress(networkName);
    const swapRouterAddr = resolveSwapRouterAddress();
    const swapQuoterAddr = resolveSwapQuoterAddress();
    const buybackConfig = resolveBuybackConfig();

    console.log("==================================================");
    console.log("  AgentPact Full Stack Deployment");
    console.log("==================================================");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("Network:", networkName, `(chainId: ${network.chainId})`);
    console.log("Platform Signer:", platformSigner);
    console.log("Platform Fund:", platformFund);
    console.log("USDC:", usdcAddress);
    console.log("WETH:", wethAddress);
    console.log("Final Owner:", finalOwner);
    if (buybackConfig) {
        console.log("Buyback Config:", buybackConfig);
    }

    const EscrowFactory = await ethers.getContractFactory("AgentPactEscrow");
    const TipJarFactory = await ethers.getContractFactory("AgentPactTipJar");
    const TreasuryFactory = await ethers.getContractFactory("AgentPactTreasury");

    console.log("\nDeploying Escrow...");
    const escrow = await upgrades.deployProxy(
        EscrowFactory,
        [platformSigner, platformFund, deployer.address],
        {
            kind: "uups",
            unsafeAllow: ["constructor", "state-variable-immutable"],
        }
    );
    await escrow.waitForDeployment();
    const escrowProxy = await escrow.getAddress();
    const escrowImpl = await waitForProxyImplementationAddress(
        escrowProxy,
        "Escrow proxy"
    );

    console.log("Deploying TipJar...");
    const tipJar = await upgrades.deployProxy(
        TipJarFactory as any,
        [usdcAddress, platformSigner, platformFund, deployer.address],
        {
            kind: "uups",
            unsafeAllow: ["constructor", "state-variable-immutable"],
        }
    );
    await tipJar.waitForDeployment();
    const tipJarProxy = await tipJar.getAddress();
    const tipJarImpl = await waitForProxyImplementationAddress(
        tipJarProxy,
        "TipJar proxy"
    );

    console.log("Deploying Treasury...");
    const treasury = await upgrades.deployProxy(
        TreasuryFactory as any,
        [platformFund, wethAddress, deployer.address],
        {
            kind: "uups",
            unsafeAllow: ["constructor"],
        }
    );
    await treasury.waitForDeployment();
    const treasuryProxy = await treasury.getAddress();
    const treasuryImpl = await waitForProxyImplementationAddress(
        treasuryProxy,
        "Treasury proxy"
    );

    console.log("\nRunning post-deploy wiring...");
    await (await (EscrowFactory.attach(escrowProxy) as any).setAllowedToken(usdcAddress, true)).wait();
    await (await (TipJarFactory.attach(tipJarProxy) as any).setUsdcToken(usdcAddress)).wait();
    await (await treasury.setAuthorizedCaller(escrowProxy, true)).wait();
    await (await treasury.setAuthorizedCaller(tipJarProxy, true)).wait();
    await (await (EscrowFactory.attach(escrowProxy) as any).setTreasury(treasuryProxy)).wait();
    await (await (TipJarFactory.attach(tipJarProxy) as any).setTreasuryContract(treasuryProxy)).wait();

    if (swapRouterAddr) {
        await (await treasury.setSwapRouter(swapRouterAddr)).wait();
    }
    if (swapQuoterAddr) {
        await (await treasury.setSwapQuoter(swapQuoterAddr)).wait();
    }
    if (buybackConfig) {
        if (buybackConfig.enabled && (!swapRouterAddr || !swapQuoterAddr)) {
            throw new Error(
                "BUYBACK_ENABLED=true requires both SWAP_ROUTER and SWAP_QUOTER."
            );
        }

        await (
            await treasury.setBuybackConfig(
                buybackConfig.enabled,
                buybackConfig.buybackBps,
                buybackConfig.buybackToken,
                buybackConfig.poolFee,
                buybackConfig.maxSlippageBps
            )
        ).wait();
    }

    if (finalOwner.toLowerCase() !== deployer.address.toLowerCase()) {
        console.log("\nTransferring ownership to final owner...");
        await (await (EscrowFactory.attach(escrowProxy) as any).transferOwnership(finalOwner)).wait();
        await (await (TipJarFactory.attach(tipJarProxy) as any).transferOwnership(finalOwner)).wait();
        await (await treasury.transferOwnership(finalOwner)).wait();
    }

    writeJson(ESCROW_JSON, {
        escrowProxy,
        escrowImplementation: escrowImpl,
        tipJarProxy,
        tipJarImplementation: tipJarImpl,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        owner: finalOwner,
        updatedAt: new Date().toISOString(),
    });

    writeJson(TREASURY_JSON, {
        treasuryProxy,
        treasuryImplementation: treasuryImpl,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        owner: finalOwner,
        updatedAt: new Date().toISOString(),
    });

    console.log("\n==================================================");
    console.log("Full stack deployment complete");
    console.log("Escrow Proxy:", escrowProxy);
    console.log("TipJar Proxy:", tipJarProxy);
    console.log("Treasury Proxy:", treasuryProxy);
    console.log(
        "Buyback:",
        buybackConfig
            ? `${buybackConfig.enabled ? "CONFIGURED" : "CONFIGURED_DISABLED"}`
            : "DISABLED (default)"
    );
    console.log("==================================================");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
