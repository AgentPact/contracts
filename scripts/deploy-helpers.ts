import { ethers } from "hardhat";

function sameAddress(a: string, b: string): boolean {
    return ethers.getAddress(a) === ethers.getAddress(b);
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
    return process.env.TRANSFER_OWNERSHIP_TO_FINAL_OWNER === "true";
}
