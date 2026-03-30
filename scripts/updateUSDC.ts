import { ethers } from "hardhat";
import { readContractsEnvValue } from "./contracts-env";
import {
    normalizeNetworkName,
    readEscrowJson,
    resolveUsdcAddress,
} from "./env";

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = normalizeNetworkName(network.name, network.chainId);
    const escrowJson = readEscrowJson();

    const usdcAddress = resolveUsdcAddress(networkName);
    const escrowProxyAddress =
        readContractsEnvValue("ESCROW_ADDRESS_PROXY") || escrowJson.escrowProxy;
    const tipJarProxyAddress =
        readContractsEnvValue("TIPJAR_ADDRESS_PROXY") || escrowJson.tipJarProxy;

    if (!escrowProxyAddress || !tipJarProxyAddress) {
        throw new Error(
            "Missing proxy addresses. Set ESCROW_ADDRESS_PROXY / TIPJAR_ADDRESS_PROXY or generate scripts/ESCROW.json first."
        );
    }

    console.log("Using deployer:", deployer.address);
    console.log("Target USDC:", usdcAddress);
    console.log("Escrow Proxy:", escrowProxyAddress);
    console.log("TipJar Proxy:", tipJarProxyAddress);

    const EscrowFactory = await ethers.getContractFactory("AgentPactEscrow");
    const escrow = EscrowFactory.attach(escrowProxyAddress) as any;

    const isAllowed = await escrow.allowedTokens(usdcAddress);
    if (!isAllowed) {
        console.log("\nAdding USDC to escrow whitelist...");
        const whitelistTx = await escrow.setAllowedToken(usdcAddress, true);
        await whitelistTx.wait();
        console.log("Escrow whitelist updated.");
    } else {
        console.log("\nEscrow already whitelists this USDC.");
    }

    const TipJarFactory = await ethers.getContractFactory("AgentPactTipJar");
    const tipJar = TipJarFactory.attach(tipJarProxyAddress) as any;

    const currentUsdc = await tipJar.usdcToken();
    if (currentUsdc.toLowerCase() !== usdcAddress.toLowerCase()) {
        console.log("\nUpdating TipJar USDC token...");
        const tipJarTx = await tipJar.setUsdcToken(usdcAddress);
        await tipJarTx.wait();
        console.log("TipJar USDC updated.");
    } else {
        console.log("\nTipJar already points to this USDC.");
    }

    console.log("\nDone.");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
