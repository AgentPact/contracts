// Deploy script for Base Sepolia
import { createPublicClient, createWalletClient, http, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import fs from "fs";

// Load environment variables
const privateKey = process.env.PRIVATE_KEY;
const platformSigner = process.env.PLATFORM_SIGNER;
const platformFund = process.env.PLATFORM_FUND;
const owner = process.env.OWNER;

const account = privateKeyToAccount(`0x${privateKey}`);
const publicClient = createPublicClient({ chain: baseSepolia, transport: http() });
const walletClient = createWalletClient({ account, chain: baseSepolia, transport: http() });

async function deploy() {
    console.log(`Deploying from account: ${account.address}`);

    // 1. Load Artifacts
    console.log("Loading artifacts...");
    const rawEscrow = fs.readFileSync("../contracts/out/ClawPactEscrowV2.sol/ClawPactEscrowV2.json", "utf-8");
    const escrowArtifact = JSON.parse(rawEscrow);

    const rawProxy = fs.readFileSync("../contracts/out/ERC1967Proxy.sol/ERC1967Proxy.json", "utf-8");
    const proxyArtifact = JSON.parse(rawProxy);

    // 2. Deploy Implementation
    console.log("Deploying implementation...");
    const implHash = await walletClient.deployContract({
        abi: escrowArtifact.abi,
        bytecode: escrowArtifact.bytecode.object,
    });
    console.log(`Impl tx: ${implHash}`);
    const implReceipt = await publicClient.waitForTransactionReceipt({ hash: implHash });
    const implAddress = implReceipt.contractAddress;
    console.log(`Implementation address: ${implAddress}`);

    // 3. Encode Initialize calldata
    // initialize(address platformSigner, address platformFund, address initialOwner)
    const initData = encodeFunctionData({
        abi: escrowArtifact.abi,
        functionName: "initialize",
        args: [platformSigner, platformFund, owner]
    });

    // 4. Deploy Proxy
    console.log("Deploying Proxy...");
    const proxyHash = await walletClient.deployContract({
        abi: proxyArtifact.abi,
        bytecode: proxyArtifact.bytecode.object,
        args: [implAddress, initData]
    });
    console.log(`Proxy tx: ${proxyHash}`);
    const proxyReceipt = await publicClient.waitForTransactionReceipt({ hash: proxyHash });
    const proxyAddress = proxyReceipt.contractAddress;
    console.log(`Proxy Address: ${proxyAddress}`);

    // 5. Save to .env.local in Platform
    console.log("Saving proxy address to platform...");
    const platformEnvPath = "../platform/.env.local";
    let platformEnv = fs.readFileSync(platformEnvPath, "utf-8");
    platformEnv = platformEnv.replace(
        /NEXT_PUBLIC_ESCROW_ADDRESS=".*"/,
        `NEXT_PUBLIC_ESCROW_ADDRESS="${proxyAddress}"`
    );
    fs.writeFileSync(platformEnvPath, platformEnv);
    console.log("Deployed & config updated successfully! 🚀");
}

deploy().catch(console.error);
