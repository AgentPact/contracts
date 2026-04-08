import { ethers } from "hardhat";
import { readContractsEnvFlag } from "./contracts-env";

const ERC1967_IMPLEMENTATION_SLOT =
    "0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC";

function sameAddress(a: string, b: string): boolean {
    return ethers.getAddress(a) === ethers.getAddress(b);
}

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function assertDeployerControlsOwnerActions(
    contract: { owner?: () => Promise<string> },
    label: string,
    deployerAddress: string
): Promise<string | undefined> {
    if (typeof contract.owner !== "function") {
        return undefined;
    }

    const owner = await contract.owner();
    if (!sameAddress(owner, deployerAddress)) {
        throw new Error(
            `${label} owner is ${owner}. Current deployer ${deployerAddress} cannot execute owner-only actions. Run this script from the current owner or governance safe.`
        );
    }

    return owner;
}

export async function transferOwnershipIfRequested(
    contract: {
        owner?: () => Promise<string>;
        transferOwnership?: (nextOwner: string) => Promise<{ wait: () => Promise<unknown> }>;
    },
    label: string,
    finalOwner: string,
    deployerAddress: string,
    transferRequested: boolean
): Promise<boolean> {
    if (!transferRequested || sameAddress(finalOwner, deployerAddress)) {
        return false;
    }

    if (
        typeof contract.owner !== "function" ||
        typeof contract.transferOwnership !== "function"
    ) {
        throw new Error(`${label} does not expose Ownable ownership controls.`);
    }

    const owner = await contract.owner();
    if (!sameAddress(owner, deployerAddress)) {
        throw new Error(
            `${label} owner is ${owner}. Current deployer ${deployerAddress} cannot transfer ownership.`
        );
    }

    const tx = await contract.transferOwnership(finalOwner);
    await tx.wait();
    console.log(`${label} ownership transferred to ${finalOwner}`);
    return true;
}

export function shouldTransferOwnershipByDefault(): boolean {
    return readContractsEnvFlag("TRANSFER_OWNERSHIP_TO_FINAL_OWNER");
}

export async function waitForProxyImplementationAddress(
    proxyAddress: string,
    label: string,
    options: {
        attempts?: number;
        delayMs?: number;
    } = {}
): Promise<string> {
    const attempts = options.attempts ?? 12;
    const delayMs = options.delayMs ?? 2_000;

    for (let attempt = 1; attempt <= attempts; attempt++) {
        const code = await ethers.provider.getCode(proxyAddress);
        const slotValue = await ethers.provider.getStorage(
            proxyAddress,
            ERC1967_IMPLEMENTATION_SLOT
        );

        if (code !== "0x" && slotValue !== ethers.ZeroHash) {
            const implementationAddress = ethers.getAddress(
                `0x${slotValue.slice(-40)}`
            );
            const implementationCode = await ethers.provider.getCode(
                implementationAddress
            );

            if (implementationCode !== "0x") {
                return implementationAddress;
            }
        }

        if (attempt < attempts) {
            console.log(
                `${label}: waiting for ERC1967 implementation slot to become visible on RPC (attempt ${attempt}/${attempts})...`
            );
            await sleep(delayMs);
        }
    }

    throw new Error(
        `${label}: proxy deployed at ${proxyAddress}, but the ERC1967 implementation slot was not readable after ${attempts} attempts. This usually means the RPC endpoint is lagging or inconsistent; retry with a dedicated Base Sepolia RPC.`
    );
}
