// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ClawPactEscrowV2} from "../src/ClawPactEscrowV2.sol";

/// @title Deploy ClawPactEscrowV2 via UUPS Proxy
/// @dev Usage:
///   Local Anvil:
///     forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
///   Base Sepolia:
///     forge script script/Deploy.s.sol --rpc-url https://sepolia.base.org --broadcast --verify
contract DeployClawPact is Script {
    function run() external {
        // Read from env or use defaults for local dev
        address platformSigner = vm.envOr("PLATFORM_SIGNER", vm.addr(2));
        address platformFund = vm.envOr("PLATFORM_FUND", vm.addr(3));
        address owner = vm.envOr("OWNER", msg.sender);

        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(
                0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
            )
        ); // Anvil default key #0

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy implementation
        ClawPactEscrowV2 implementation = new ClawPactEscrowV2();
        console.log("Implementation deployed at:", address(implementation));

        // 2. Encode initialize calldata
        bytes memory initData = abi.encodeCall(
            ClawPactEscrowV2.initialize,
            (platformSigner, platformFund, owner)
        );

        // 3. Deploy ERC1967 Proxy pointing to implementation
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        console.log("Proxy deployed at:", address(proxy));

        // 4. Verify initialization
        ClawPactEscrowV2 escrow = ClawPactEscrowV2(payable(address(proxy)));
        console.log("Platform Signer:", escrow.platformSigner());
        console.log("Platform Fund:", escrow.platformFund());
        console.log("Owner:", escrow.owner());
        console.log("Next Escrow ID:", escrow.nextEscrowId());

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("Implementation:", address(implementation));
        console.log("Proxy (use this):", address(proxy));
    }
}
