import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";
import { readContractsEnvValue } from "./contracts-env";
import {
    normalizeNetworkName,
    readEscrowJson,
    resolveBuybackConfig,
    resolveContractOwner,
    resolvePlatformFundAddress,
    resolveSwapQuoterAddress,
    resolveSwapRouterAddress,
    resolveWethAddress,
} from "./env";
import {
    assertDeployerControlsOwnerActions,
    shouldTransferOwnershipByDefault,
    transferOwnershipIfRequested,
} from "./deploy-helpers";

const TREASURY_JSON = path.join(__dirname, "TREASURY.json");

interface TreasuryAddresses {
    treasuryProxy: string;
    treasuryImplementation: string;
    network: string;
    chainId: number;
    deployer: string;
    owner: string;
    updatedAt: string;
}

function saveTreasuryJson(data: TreasuryAddresses) {
    fs.writeFileSync(TREASURY_JSON, JSON.stringify(data, null, 2));
    console.log("scripts/TREASURY.json updated");
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = normalizeNetworkName(network.name, network.chainId);
    const balance = await ethers.provider.getBalance(deployer.address);
    const finalOwner = resolveContractOwner(networkName, deployer.address);
    const platformWallet = resolvePlatformFundAddress(
        networkName,
        deployer.address
    );
    const wethAddress = resolveWethAddress(networkName);
    const swapRouterAddr = resolveSwapRouterAddress();
    const swapQuoterAddr = resolveSwapQuoterAddress();
    const buybackConfig = resolveBuybackConfig();
    const transferOwnership = shouldTransferOwnershipByDefault();
    const escrowJson = readEscrowJson();

    console.log("==================================================");
    console.log("  AgentPact Treasury Deployment");
    console.log("==================================================");
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("Network:", networkName, `(chainId: ${network.chainId})`);
    console.log("Platform Wallet:", platformWallet);
    console.log("WETH:", wethAddress);
    console.log("Final Owner:", finalOwner);
    console.log("Transfer Ownership:", transferOwnership);
    if (buybackConfig) {
        console.log("Buyback Config:", buybackConfig);
    }

    if (balance === 0n) {
        throw new Error("Deployer has 0 ETH - please fund the wallet first");
    }

    const TreasuryFactory = await ethers.getContractFactory("AgentPactTreasury");
    const existingProxy = readContractsEnvValue("TREASURY_ADDRESS_PROXY");

    let treasuryProxyAddress: string;
    let treasuryImplAddress: string;

    if (existingProxy) {
        const existingTreasury = TreasuryFactory.attach(existingProxy) as any;
        await assertDeployerControlsOwnerActions(
            existingTreasury,
            "Treasury",
            deployer.address
        );

        console.log("\nUpgrading Treasury...");
        const upgraded = await upgrades.upgradeProxy(existingProxy, TreasuryFactory as any, {
            kind: "uups",
            unsafeAllow: ["constructor"],
        });
        await upgraded.waitForDeployment();
        treasuryProxyAddress = existingProxy;
        treasuryImplAddress = await upgrades.erc1967.getImplementationAddress(treasuryProxyAddress);
        console.log("Upgraded:", treasuryProxyAddress);
    } else {
        console.log("\nDeploying Treasury...");
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
        console.log("Deployed:", treasuryProxyAddress);
    }

    const treasury = (await ethers.getContractAt(
        "AgentPactTreasury",
        treasuryProxyAddress
    )) as any;
    await assertDeployerControlsOwnerActions(
        treasury,
        "Treasury",
        deployer.address
    );

    const escrowProxy =
        readContractsEnvValue("ESCROW_ADDRESS_PROXY") || escrowJson.escrowProxy;
    const tipJarProxy =
        readContractsEnvValue("TIPJAR_ADDRESS_PROXY") || escrowJson.tipJarProxy;

    if (escrowProxy) {
        const escrow = (await ethers.getContractAt(
            "AgentPactEscrow",
            escrowProxy
        )) as any;
        try {
            await assertDeployerControlsOwnerActions(
                escrow,
                "Escrow",
                deployer.address
            );
            console.log("\nAuthorizing Escrow as Treasury caller...");
            await (await treasury.setAuthorizedCaller(escrowProxy, true)).wait();
            console.log("Escrow authorized");

            console.log("Setting Treasury on Escrow...");
            await (await escrow.setTreasury(treasuryProxyAddress)).wait();
            console.log("Escrow -> Treasury linked");
        } catch (error) {
            console.log(
                `Skipped Escrow auto-linking: ${(error as Error).message}`
            );
        }
    }

    if (tipJarProxy) {
        const tipJar = (await ethers.getContractAt(
            "AgentPactTipJar",
            tipJarProxy
        )) as any;
        try {
            await assertDeployerControlsOwnerActions(
                tipJar,
                "TipJar",
                deployer.address
            );
            console.log("\nAuthorizing TipJar as Treasury caller...");
            await (await treasury.setAuthorizedCaller(tipJarProxy, true)).wait();
            console.log("TipJar authorized");

            console.log("Setting Treasury on TipJar...");
            await (await tipJar.setTreasuryContract(treasuryProxyAddress)).wait();
            console.log("TipJar -> Treasury linked");
        } catch (error) {
            console.log(
                `Skipped TipJar auto-linking: ${(error as Error).message}`
            );
        }
    }

    if (swapRouterAddr) {
        console.log("\nConfiguring Uniswap SwapRouter...");
        await (await treasury.setSwapRouter(swapRouterAddr)).wait();
        console.log("SwapRouter:", swapRouterAddr);
    }

    if (swapQuoterAddr) {
        console.log("Configuring Uniswap SwapQuoter...");
        await (await treasury.setSwapQuoter(swapQuoterAddr)).wait();
        console.log("SwapQuoter:", swapQuoterAddr);
    }

    if (buybackConfig) {
        if (buybackConfig.enabled && (!swapRouterAddr || !swapQuoterAddr)) {
            throw new Error(
                "BUYBACK_ENABLED=true requires both SWAP_ROUTER and SWAP_QUOTER."
            );
        }

        console.log("Configuring Treasury buyback settings...");
        await (
            await treasury.setBuybackConfig(
                buybackConfig.enabled,
                buybackConfig.buybackBps,
                buybackConfig.buybackToken,
                buybackConfig.poolFee,
                buybackConfig.maxSlippageBps
            )
        ).wait();
        console.log(
            "Buyback configured:",
            buybackConfig.buybackToken,
            `(enabled=${buybackConfig.enabled})`
        );
    }

    await transferOwnershipIfRequested(
        treasury,
        "Treasury",
        finalOwner,
        deployer.address,
        transferOwnership && !existingProxy
    );

    saveTreasuryJson({
        treasuryProxy: treasuryProxyAddress,
        treasuryImplementation: treasuryImplAddress,
        network: networkName,
        chainId: Number(network.chainId),
        deployer: deployer.address,
        owner:
            transferOwnership && !existingProxy ? finalOwner : deployer.address,
        updatedAt: new Date().toISOString(),
    });

    console.log("\n==================================================");
    console.log("  Treasury deployment complete!");
    console.log("  Proxy:", treasuryProxyAddress);
    console.log(
        "  Buyback:",
        buybackConfig
            ? `${buybackConfig.enabled ? "CONFIGURED" : "CONFIGURED_DISABLED"}`
            : "DISABLED (default)"
    );
    if (!buybackConfig) {
        console.log("");
        console.log("  To enable buyback, call:");
        console.log("  treasury.setBuybackConfig(true, 5000, <TOKEN>, 3000, 500)");
    }
    if (!escrowProxy || !tipJarProxy) {
        console.log(
            "\n  Set ESCROW_ADDRESS_PROXY and TIPJAR_ADDRESS_PROXY to auto-link."
        );
    }
    if (!transferOwnership && finalOwner.toLowerCase() !== deployer.address.toLowerCase()) {
        console.log(
            "  Ownership transfer skipped. Re-run with TRANSFER_OWNERSHIP_TO_FINAL_OWNER=true once linking is complete."
        );
    }
    console.log("==================================================");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
