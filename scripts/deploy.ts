import { ethers, upgrades } from "hardhat";
import fs from "fs";
import path from "path";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address);

    // You can set these via environment vars or hardcode for testnet
    const platformSigner = process.env.PLATFORM_SIGNER || "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
    const platformFund = process.env.PLATFORM_FUND || "0x2060b0212755e8d8972dd473ba66757192704deb";
    const initialOwner = deployer.address;

    // Compile and Deploy via OpenZeppelin Hardhat Upgrades plugin
    const EscrowFactory = await ethers.getContractFactory("ClawPactEscrowV2");

    console.log("Deploying ClawPactEscrowV2 as UUPS Proxy...");
    const escrow = await upgrades.deployProxy(
        EscrowFactory,
        [platformSigner, platformFund, initialOwner],
        { kind: "uups" } // automatically handles implementation, proxy and init call
    );

    await escrow.waitForDeployment();
    const proxyAddress = await escrow.getAddress();

    console.log("🚀 ClawPactEscrowV2 Proxy deployed to:", proxyAddress);

    // Optionally update backend environment automatically
    const envPath = path.join(__dirname, "../../platform/.env.local");
    if (fs.existsSync(envPath)) {
        let envContent = fs.readFileSync(envPath, "utf-8");
        envContent = envContent.replace(
            /NEXT_PUBLIC_ESCROW_ADDRESS=".*"/,
            `NEXT_PUBLIC_ESCROW_ADDRESS="${proxyAddress}"`
        );
        fs.writeFileSync(envPath, envContent);
        console.log("Backend .env.local updated with new Escrow Address.");
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
