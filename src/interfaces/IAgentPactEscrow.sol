// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentPactEscrow
/// @notice Interface for the AgentPact trustless escrow contract
/// @dev All functions are called directly by requester or provider, never by the platform
interface IAgentPactEscrow {
    enum TaskState {
        Created,
        ConfirmationPending,
        Working,
        Delivered,
        InRevision,
        Accepted,
        Settled,
        TimedOut,
        Cancelled
    }

    struct EscrowRecord {
        address requester;
        address provider;
        uint256 rewardAmount;
        uint256 requesterDeposit;
        uint256 depositConsumed;
        address token;
        TaskState state;
        bytes32 taskHash;
        bytes32 latestDeliveryHash;
        bytes32 latestCriteriaHash;
        uint64 deliveryDurationSeconds;
        uint64 deliveryDeadline;
        uint64 acceptanceDeadline;
        uint64 confirmationDeadline;
        uint8 maxRevisions;
        uint8 currentRevision;
        uint8 criteriaCount;
        uint8 declineCount;
        uint8 acceptanceWindowHours;
    }

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed requester,
        bytes32 taskHash,
        uint256 rewardAmount,
        uint256 requesterDeposit,
        address token,
        uint64 deliveryDurationSeconds,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours,
        uint8 criteriaCount
    );

    event TaskClaimed(
        uint256 indexed escrowId,
        address indexed provider,
        uint64 confirmationDeadline
    );

    event TaskConfirmed(
        uint256 indexed escrowId,
        address indexed provider,
        uint64 deliveryDeadline
    );

    event TaskDeclined(uint256 indexed escrowId, address indexed provider);

    event TaskSuspendedAfterDeclines(
        uint256 indexed escrowId,
        uint8 declineCount
    );

    event TaskAbandoned(uint256 indexed escrowId, address indexed provider);

    event DeliverySubmitted(
        uint256 indexed escrowId,
        bytes32 deliveryHash,
        uint8 revision,
        uint64 acceptanceDeadline
    );

    event DeliveryAccepted(
        uint256 indexed escrowId,
        uint256 providerPayout,
        uint256 platformFee
    );

    event RevisionRequested(
        uint256 indexed escrowId,
        bytes32 reasonHash,
        bytes32 criteriaResultsHash,
        uint8 currentRevision,
        uint256 depositPenalty,
        uint8 passRate
    );

    event TaskAutoSettled(
        uint256 indexed escrowId,
        uint8 passRate,
        uint256 providerShare,
        uint256 requesterRefund,
        uint256 platformFee
    );

    event TimeoutClaimed(
        uint256 indexed escrowId,
        TaskState previousState,
        address indexed claimedBy
    );

    event TaskCancelled(
        uint256 indexed escrowId,
        uint256 compensation
    );

    event PlatformFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    function totalClosedEscrows() external view returns (uint256);

    function totalSuccessfulEscrows() external view returns (uint256);

    function totalRewardVolumeByToken(address token) external view returns (uint256);

    function totalPayoutVolumeByToken(address token) external view returns (uint256);

    function createEscrow(
        bytes32 taskHash,
        uint64 deliveryDurationSeconds,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours,
        uint8 criteriaCount,
        uint8[] calldata fundWeights,
        address token,
        uint256 totalAmount
    ) external payable returns (uint256 escrowId);

    function acceptDelivery(uint256 escrowId) external;

    function requestRevision(
        uint256 escrowId,
        bytes32 reasonHash,
        bool[] calldata criteriaResults
    ) external;

    function cancelTask(uint256 escrowId) external;

    function claimTask(
        uint256 escrowId,
        uint256 nonce,
        uint256 expiredAt,
        bytes calldata platformSignature
    ) external;

    function confirmTask(uint256 escrowId) external;

    function declineTask(uint256 escrowId) external;

    function submitDelivery(uint256 escrowId, bytes32 deliveryHash) external;

    function abandonTask(uint256 escrowId) external;

    function claimAcceptanceTimeout(uint256 escrowId) external;

    function claimDeliveryTimeout(uint256 escrowId) external;

    function claimConfirmationTimeout(uint256 escrowId) external;

    function setPlatformFeeBps(uint16 newFeeBps) external;
}
