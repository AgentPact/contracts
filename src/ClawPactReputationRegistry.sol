// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IIdentityRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
    function primaryAgentId(address owner) external view returns (uint256);
    function hasPrimaryAgent(address owner) external view returns (bool);
}

/**
 * @title ClawPactReputationRegistry
 * @dev Implementation of a simplified ERC-8004 Reputation Registry for AI Agents.
 * Allows recording reviews, performance metrics, and positive feedback on-chain.
 */
contract ClawPactReputationRegistry is OwnableUpgradeable, UUPSUpgradeable {
    IIdentityRegistry public identityRegistry;

    // Mapping to track authorized writers (e.g., Escrow contract, TipJar contract)
    mapping(address => bool) public authorizedWriters;

    struct Attestation {
        uint256 agentId;
        address source; // Who provided the attestation (e.g., user, authorized contract)
        string category; // e.g., "TASK_COMPLETION", "TIP_RECEIVED", "KNOWLEDGE_VERIFIED"
        int256 score; // Positive/negative impact (e.g., 1 to 5, or specific metric)
        string dataURI; // IPFS or HTTP link to detailed feedback/evidence
        uint256 timestamp;
    }

    event AttestationRecorded(
        uint256 indexed agentId,
        address indexed source,
        string category,
        int256 score,
        string dataURI,
        uint256 timestamp
    );

    event WriterAuthorized(address writer, bool status);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address _identityRegistry
    ) public initializer {
        __Ownable_init(initialOwner);
        identityRegistry = IIdentityRegistry(_identityRegistry);
    }

    /**
     * @dev Records a reputation attestation for an Agent using their address.
     * Silently ignores if the target address has not minted an Agent NFT yet (to avoid blocking funds).
     * @param target Agent's owner address
     * @param category The type of feedback.
     * @param score A numerical score for the feedback.
     * @param dataURI URI to detailed feedback.
     */
    function recordAttestation(
        address target,
        string calldata category,
        int256 score,
        string calldata dataURI
    ) external {
        if (!identityRegistry.hasPrimaryAgent(target)) {
            return; // Target has no agent identity, ignore the attestation
        }

        uint256 agentId = identityRegistry.primaryAgentId(target);

        emit AttestationRecorded(
            agentId,
            msg.sender,
            category,
            score,
            dataURI,
            block.timestamp
        );
    }

    /**
     * @dev Authorizes a specific contract (like Escrow or TipJar) to be recognized
     * as an "official" writer. This is primarily for off-chain indexing or
     * advanced on-chain weighting.
     */
    function setAuthorizedWriter(
        address writer,
        bool status
    ) external onlyOwner {
        authorizedWriters[writer] = status;
        emit WriterAuthorized(writer, status);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
