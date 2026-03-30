import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";
import { readContractsEnvValue } from "./contracts-env";
import {
    normalizeNetworkName,
    resolveContractOwner,
} from "./env";
import {
    assertDeployerControlsOwnerActions,
    shouldTransferOwnershipByDefault,
    transferOwnershipIfRequested,
} from "./deploy-helpers";

const ERC8004_JSON = path.join(__dirname, "ERC8004.json");

interface ERC8004Addresses {
    identityProxy: string;
    identityImplementation: string;
    reputationProxy: string;
    reputationImplementation: string;
    network: string;
    chainId: number;
    deployer: string;
    owner: string;
    updatedAt: string;
}

function saveERC8004Json(data: ERC8004Addresses) {
    fs.writeFileSync(ERC8004_JSON, JSON.stringify(data, null, 2));
    console.log("scripts/ERC8004.json updated");
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = normalizeNetworkName(network.name, network.chainId);
    const balance = await ethers.provider.getBalance(deployer.address);
    const finalOwner = resolveContractOwner(networkName, deployer.address);
    const transferOwnership = shouldTransferOwnershipByDefault();

    console.log("==================================================");
    console.log("  AgentPact ERC-8004 Deployment");
    console.log("==================================================");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("Network:", networkName, `(chainId: ${network.chainId})`);
    console.log("Final Owner:", finalOwner);
    console.log("Transfer Ownership:", transferOwnership);

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH - please fund the wallet first");
    }

    const IdentityFactory = await ethers.getContractFactory(
        "AgentPactIdentityRegistry"
    );
    const ReputationFactory = await ethers.getContractFactory(
        "AgentPactReputationRegistry"
    );

    const existingIdentityProxy = readContractsEnvValue("IDENTITY_ADDRESS_PROXY");
    const existingReputationProxy = readContractsEnvValue("REPUTATION_ADDRESS_PROXY");

    let identityProxyAddress: string;
    let identityImplAddress: string;
    let reputationProxyAddress: string;
    let reputationImplAddress: string;

    if (existingIdentityProxy) {
        const existingIdentity = IdentityFactory.attach(existingIdentityProxy) as any;
        await assertDeployerControlsOwnerActions(
            existingIdentity,
            "IdentityRegistry",
            deployer.address
        );

        console.log("\nUpgrading Identity Registry...");
        const upgraded = await upgrades.upgradeProxy(
            existingIdentityProxy,
            IdentityFactory as any,
            { kind: "uups" }
        );
        await upgraded.waitForDeployment();
        identityProxyAddress = existingIdentityProxy;
        identityImplAddress = await upgrades.erc1967.getImplementationAddress(
            identityProxyAddress
        );
    } else {
        console.log("\nDeploying Identity Registry...");
        const identity = await upgrades.deployProxy(
            IdentityFactory as any,
            [deployer.address],
            { kind: "uups" }
        );
        await identity.waitForDeployment();
        identityProxyAddress = await identity.getAddress();
        identityImplAddress = await upgrades.erc1967.getImplementationAddress(
            identityProxyAddress
        );
    }

    if (existingReputationProxy) {
        const existingReputation = ReputationFactory.attach(
            existingReputationProxy
        ) as any;
        await assertDeployerControlsOwnerActions(
            existingReputation,
            "ReputationRegistry",
            deployer.address
        );

        console.log("\nUpgrading Reputation Registry...");
        const upgraded = await upgrades.upgradeProxy(
            existingReputationProxy,
            ReputationFactory as any,
            { kind: "uups" }
        );
        await upgraded.waitForDeployment();
        reputationProxyAddress = existingReputationProxy;
        reputationImplAddress = await upgrades.erc1967.getImplementationAddress(
            reputationProxyAddress
        );
    } else {
        console.log("\nDeploying Reputation Registry...");
        const reputation = await upgrades.deployProxy(
            ReputationFactory as any,
            [deployer.address, identityProxyAddress],
            { kind: "uups" }
        );
        await reputation.waitForDeployment();
        reputationProxyAddress = await reputation.getAddress();
        reputationImplAddress = await upgrades.erc1967.getImplementationAddress(
            reputationProxyAddress
        );
    }

    const tipJarProxy = readContractsEnvValue("TIPJAR_ADDRESS_PROXY");
    if (tipJarProxy) {
        const reputation = (await ethers.getContractAt(
            "AgentPactReputationRegistry",
            reputationProxyAddress
        )) as any;

        await assertDeployerControlsOwnerActions(
            reputation,
            "ReputationRegistry",
            deployer.address
        );

        console.log("\nAuthorizing TipJar as a reputation writer...");
        await (await reputation.setAuthorizedWriter(tipJarProxy, true)).wait();
        console.log("TipJar authorized:", tipJarProxy);
    }

    const identity = IdentityFactory.attach(identityProxyAddress) as any;
    const reputation = ReputationFactory.attach(reputationProxyAddress) as any;

    await transferOwnershipIfRequested(
        identity,
        "IdentityRegistry",
        finalOwner,
        deployer.address,
        transferOwnership && !existingIdentityProxy
    );
    await transferOwnershipIfRequested(
        reputation,
        "ReputationRegistry",
        finalOwner,
        deployer.address,
        transferOwnership && !existingReputationProxy
    );

    saveERC8004Json({
        identityProxy: identityProxyAddress,
        identityImplementation: identityImplAddress,
        reputationProxy: reputationProxyAddress,
        reputationImplementation: reputationImplAddress,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        owner:
            transferOwnership && !existingIdentityProxy
                ? finalOwner
                : deployer.address,
        updatedAt: new Date().toISOString(),
    });

    console.log("\n==================================================");
    console.log("ERC-8004 deployment complete");
    console.log("Identity Proxy:", identityProxyAddress);
    console.log("Reputation Proxy:", reputationProxyAddress);
    if (!tipJarProxy) {
        console.log(
            "TipJar auto-authorization skipped. Set TIPJAR_ADDRESS_PROXY to wire it automatically."
        );
    }
    console.log("==================================================");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
