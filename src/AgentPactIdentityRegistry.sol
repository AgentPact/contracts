// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ERC721URIStorageUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title AgentPactIdentityRegistry
 * @dev Implementation of a simplified ERC-8004 Identity Registry for AI Agents.
 *      NOTE: This contract is currently NOT enabled in production flows.
 *      It is kept for future ERC-8004-aligned identity work and should not be
 *      treated as an active protocol dependency yet.
 * Each NFT represents a unique Agent identity.
 */
contract AgentPactIdentityRegistry is
    ERC721URIStorageUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    uint256 private _nextTokenId;

    /// @notice Reverse lookup: wallet address => primary Agent ID
    mapping(address => uint256) public primaryAgentId;
    /// @notice Tracks if an address has a primary agent set
    mapping(address => bool) public hasPrimaryAgent;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __ERC721_init("AgentPact Agent Identity", "APAI");
        __ERC721URIStorage_init();
        __Ownable_init(initialOwner);
    }

    /**
     * @dev Mints a new Agent Identity NFT.
     * @param to The address that will own the Agent Identity.
     * @param metadataURI The URI pointing to the Agent's off-chain metadata (e.g., capabilities, name).
     * @return The newly created Agent ID.
     */
    function registerAgent(
        address to,
        string memory metadataURI
    ) external returns (uint256) {
        require(msg.sender == to, "Self registration only");
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, metadataURI);

        if (!hasPrimaryAgent[to]) {
            primaryAgentId[to] = tokenId;
            hasPrimaryAgent[to] = true;
        }

        return tokenId;
    }

    /**
     * @dev Allows an owner of multiple agent NFTs to set their primary identity.
     */
    function setPrimaryAgentId(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner of Agent NFT");
        primaryAgentId[msg.sender] = tokenId;
        hasPrimaryAgent[msg.sender] = true;
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = super._update(to, tokenId, auth);

        if (from != address(0) && primaryAgentId[from] == tokenId) {
            primaryAgentId[from] = 0;
            hasPrimaryAgent[from] = false;
        }

        if (to != address(0) && !hasPrimaryAgent[to]) {
            primaryAgentId[to] = tokenId;
            hasPrimaryAgent[to] = true;
        }

        return from;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
