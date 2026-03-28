import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";
import {
    normalizeNetworkName,
    resolveContractOwner,
    resolvePlatformFundAddress,
    resolvePlatformSignerAddress,
    resolveUsdcAddress,
} from "./env";
import {
    assertDeployerControlsOwnerActions,
    shouldTransferOwnershipByDefault,
    transferOwnershipIfRequested,
} from "./deploy-helpers";

const ESCROW_JSON = path.join(__dirname, "ESCROW.json");

interface EscrowAddresses {
    escrowProxy: string;
    escrowImplementation: string;
    tipJarProxy: string;
    tipJarImplementation: string;
    network: string;
    chainId: number;
    deployer: string;
    owner: string;
    updatedAt: string;
}

function saveEscrowJson(data: EscrowAddresses) {
    fs.writeFileSync(ESCROW_JSON, JSON.stringify(data, null, 2));
    console.log("scripts/ESCROW.json updated");
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
    console.log(`${path.basename(envPath)} -> ${key}`);
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = normalizeNetworkName(network.name, network.chainId);
    const balance = await ethers.provider.getBalance(deployer.address);
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
    const transferOwnership = shouldTransferOwnershipByDefault();

    console.log("==================================================");
    console.log("  AgentPact Escrow Deployment");
    console.log("==================================================");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("Network:", networkName, `(chainId: ${network.chainId})`);
    console.log("Platform Signer:", platformSigner);
    console.log("Platform Fund:", platformFund);
    console.log("Final Owner:", finalOwner);
    console.log("Transfer Ownership:", transferOwnership);

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH - please fund the wallet first");
    }

    const EscrowFactory = await ethers.getContractFactory("AgentPactEscrow");
    const existingProxy = process.env.ESCROW_ADDRESS_PROXY?.trim();

    let proxyAddress: string;
    let implAddress: string;

    if (existingProxy) {
        console.log("\nUpgrade mode - proxy already deployed");
        console.log("Existing Proxy:", existingProxy);

        const existingEscrow = EscrowFactory.attach(existingProxy) as any;
        await assertDeployerControlsOwnerActions(
            existingEscrow,
            "Escrow",
            deployer.address
        );

        const oldImpl = await upgrades.erc1967.getImplementationAddress(existingProxy);
        console.log("Old Implementation:", oldImpl);

        console.log("\nDeploying new implementation and upgrading proxy...");
        const upgraded = await upgrades.upgradeProxy(existingProxy, EscrowFactory, {
            kind: "uups",
            unsafeAllow: ["constructor", "state-variable-immutable"],
        });
        await upgraded.waitForDeployment();

        proxyAddress = existingProxy;
        implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

        console.log("\nEscrow upgrade successful");
        console.log("Proxy:", proxyAddress);
        console.log("Implementation:", implAddress);
    } else {
        console.log("\nFresh deploy mode - no existing escrow proxy found");
        console.log("Temporary Owner:", deployer.address);

        console.log("\nDeploying Escrow UUPS proxy and implementation...");
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

        console.log("\nEscrow fresh deploy successful");
        console.log("Proxy:", proxyAddress);
        console.log("Implementation:", implAddress);
    }

    const TipJarFactory = await ethers.getContractFactory("AgentPactTipJar");
    const existingTipJarProxy = process.env.TIPJAR_ADDRESS_PROXY?.trim();

    let tipJarProxyAddress: string;
    let tipJarImplAddress: string;

    if (existingTipJarProxy) {
        console.log("\nTipJar upgrade mode - proxy already deployed");
        console.log("Existing TipJar Proxy:", existingTipJarProxy);

        const existingTipJar = TipJarFactory.attach(existingTipJarProxy) as any;
        await assertDeployerControlsOwnerActions(
            existingTipJar,
            "TipJar",
            deployer.address
        );

        const oldTipJarImpl = await upgrades.erc1967.getImplementationAddress(existingTipJarProxy);
        console.log("Old TipJar Implementation:", oldTipJarImpl);

        console.log("\nDeploying new TipJar implementation and upgrading proxy...");
        const upgradedTipJar = await upgrades.upgradeProxy(existingTipJarProxy, TipJarFactory as any, {
            kind: "uups",
            unsafeAllow: ["constructor", "state-variable-immutable"],
        });
        await upgradedTipJar.waitForDeployment();

        tipJarProxyAddress = existingTipJarProxy;
        tipJarImplAddress = await upgrades.erc1967.getImplementationAddress(tipJarProxyAddress);

        console.log("\nTipJar upgrade successful");
        console.log("Proxy:", tipJarProxyAddress);
        console.log("Implementation:", tipJarImplAddress);
    } else {
        console.log("\nTipJar fresh deploy mode - no existing proxy found");
        console.log("USDC Address:", usdcAddress);
        console.log("Temporary Owner:", deployer.address);

        console.log("\nDeploying TipJar UUPS proxy and implementation...");
        const tipJar = await upgrades.deployProxy(
            TipJarFactory as any,
            [usdcAddress, platformSigner, platformFund, deployer.address],
            {
                kind: "uups",
                unsafeAllow: ["constructor", "state-variable-immutable"],
            }
        );
        await tipJar.waitForDeployment();

        tipJarProxyAddress = await tipJar.getAddress();
        tipJarImplAddress = await upgrades.erc1967.getImplementationAddress(tipJarProxyAddress);

        console.log("\nTipJar fresh deploy successful");
        console.log("Proxy:", tipJarProxyAddress);
        console.log("Implementation:", tipJarImplAddress);
    }

    const escrow = EscrowFactory.attach(proxyAddress) as any;
    const isUsdcAllowed = await escrow.allowedTokens(usdcAddress);
    if (!isUsdcAllowed) {
        console.log("\nWhitelisting USDC on Escrow...");
        const whitelistTx = await escrow.setAllowedToken(usdcAddress, true);
        await whitelistTx.wait();
        console.log("Escrow whitelist updated:", usdcAddress);
    } else {
        console.log("\nEscrow already whitelists USDC:", usdcAddress);
    }

    const tipJar = TipJarFactory.attach(tipJarProxyAddress) as any;
    const currentTipJarUsdc = await tipJar.usdcToken();
    if (currentTipJarUsdc.toLowerCase() !== usdcAddress.toLowerCase()) {
        console.log("\nUpdating TipJar USDC token...");
        const setUsdcTx = await tipJar.setUsdcToken(usdcAddress);
        await setUsdcTx.wait();
        console.log("TipJar USDC updated:", usdcAddress);
    } else {
        console.log("\nTipJar already uses USDC:", usdcAddress);
    }

    await transferOwnershipIfRequested(
        escrow,
        "Escrow",
        finalOwner,
        deployer.address,
        transferOwnership && !existingProxy
    );
    await transferOwnershipIfRequested(
        tipJar,
        "TipJar",
        finalOwner,
        deployer.address,
        transferOwnership && !existingTipJarProxy
    );

    saveEscrowJson({
        escrowProxy: proxyAddress,
        escrowImplementation: implAddress,
        tipJarProxy: tipJarProxyAddress,
        tipJarImplementation: tipJarImplAddress,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        owner:
            transferOwnership && !existingProxy ? finalOwner : deployer.address,
        updatedAt: new Date().toISOString(),
    });

    if (process.env.UPDATE_PLATFORM_ENV === "true") {
        updateEnvFile(path.join(__dirname, "../../platform/.env"), "ESCROW_ADDRESS", proxyAddress);
        updateEnvFile(path.join(__dirname, "../../platform/.env"), "TIPJAR_ADDRESS", tipJarProxyAddress);
        updateEnvFile(path.join(__dirname, "../../platform/.env"), "USDC_ADDRESS", usdcAddress);
    }

    console.log("\n==================================================");
    if (!transferOwnership && finalOwner.toLowerCase() !== deployer.address.toLowerCase()) {
        console.log(
            "Ownership transfer skipped. Re-run with TRANSFER_OWNERSHIP_TO_FINAL_OWNER=true once treasury linking is complete."
        );
    }
    console.log("Done. Verify if needed:");
    console.log(`npx hardhat verify --network ${networkName} ${proxyAddress}`);
    console.log(`npx hardhat verify --network ${networkName} ${tipJarProxyAddress}`);
    console.log("==================================================");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
