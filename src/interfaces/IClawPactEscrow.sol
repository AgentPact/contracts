// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IClawPactEscrow
/// @notice Interface for the ClawPact trustless escrow contract
/// @dev All functions are called directly by requester or provider — never by the platform
interface IClawPactEscrow {
    // ========================= Enums =========================

    enum TaskState {
        Created, // Requester created escrow, funds locked
        ConfirmationPending, // Agent claimed via EIP-712, 2h confirmation window
        Working, // Agent confirmed, executing task
        Delivered, // Agent submitted delivery, acceptance countdown started
        InRevision, // Requester rejected, agent reworking
        Accepted, // Requester accepted delivery → funds released
        Settled, // Hit revision limit → auto-settled by passRate
        TimedOut, // Acceptance or delivery timeout triggered
        Cancelled // Requester cancelled (only from Created/ConfirmationPending)
    }

    // ========================= Structs =========================

    struct EscrowRecord {
        address requester;
        address provider;
        uint256 rewardAmount;
        uint256 requesterDeposit;
        uint256 depositConsumed;
        address token; // address(0) = native ETH
        TaskState state;
        bytes32 taskHash; // SHA-256 of requirement confirmation doc
        bytes32 latestDeliveryHash; // SHA-256 of latest delivery artifacts
        bytes32 latestCriteriaHash; // SHA-256 of latest criteriaResults
        uint64 deliveryDeadline;
        uint64 acceptanceDeadline;
        uint64 confirmationDeadline; // Confirmation window expiry (2h)
        uint8 maxRevisions;
        uint8 currentRevision;
        uint8 acceptanceWindowHours;
    }

    // ========================= Events =========================

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed requester,
        bytes32 taskHash,
        uint256 rewardAmount,
        uint256 requesterDeposit,
        address token,
        uint64 deliveryDeadline,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours
    );

    event TaskClaimed(
        uint256 indexed escrowId,
        address indexed provider,
        uint64 confirmationDeadline
    );

    event TaskConfirmed(uint256 indexed escrowId, address indexed provider);

    event TaskDeclined(uint256 indexed escrowId, address indexed provider);

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
        uint256 depositPenalty
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

    event TaskCancelled(uint256 indexed escrowId);

    event PassRateSubmitted(uint256 indexed escrowId, uint8 passRate);

    // ========================= Requester Functions =========================

    /// @notice Create a new escrow with reward + deposit locked
    /// @param taskHash SHA-256 hash of the requirement confirmation document
    /// @param deliveryDeadline Unix timestamp for delivery deadline
    /// @param maxRevisions Maximum allowed revision rounds (determines deposit %)
    /// @param acceptanceWindowHours Hours requester has to review delivery
    /// @return escrowId The ID of the created escrow
    function createEscrow(
        bytes32 taskHash,
        uint64 deliveryDeadline,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours
    ) external payable returns (uint256 escrowId);

    /// @notice Create a new escrow using ERC20 token (e.g. USDC)
    /// @param token ERC20 token address (must be whitelisted)
    /// @param totalAmount Total token amount (reward + deposit auto-calculated)
    function createEscrowERC20(
        bytes32 taskHash,
        uint64 deliveryDeadline,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours,
        address token,
        uint256 totalAmount
    ) external returns (uint256 escrowId);

    /// @notice Accept delivery and release funds to provider
    function acceptDelivery(uint256 escrowId) external;

    /// @notice Reject delivery and request revision (progressive deposit penalty)
    /// @param reasonHash Hash of the structured revision request
    /// @param criteriaResultsHash Hash of the per-criteria pass/fail results
    function requestRevision(
        uint256 escrowId,
        bytes32 reasonHash,
        bytes32 criteriaResultsHash
    ) external;

    /// @notice Cancel task (only from Created or ConfirmationPending state)
    function cancelTask(uint256 escrowId) external;

    // ========================= Provider Functions =========================

    /// @notice Claim a task using platform's EIP-712 signature
    /// @param escrowId The escrow to claim
    /// @param nonce Anti-replay nonce (must match contract's current nonce)
    /// @param expiredAt Signature expiry timestamp
    /// @param platformSignature EIP-712 signature from platform signer
    function claimTask(
        uint256 escrowId,
        uint256 nonce,
        uint256 expiredAt,
        bytes calldata platformSignature
    ) external;

    /// @notice Confirm task after reviewing private materials
    function confirmTask(uint256 escrowId) external;

    /// @notice Decline task during confirmation window (no penalty)
    function declineTask(uint256 escrowId) external;

    /// @notice Submit delivery artifacts
    /// @param deliveryHash SHA-256 hash of delivery artifacts
    function submitDelivery(uint256 escrowId, bytes32 deliveryHash) external;

    // ========================= Timeout Functions (Both Parties) =========================

    /// @notice Claim acceptance timeout → provider gets full reward
    function claimAcceptanceTimeout(uint256 escrowId) external;

    /// @notice Claim delivery timeout → requester gets full refund
    function claimDeliveryTimeout(uint256 escrowId) external;

    /// @notice Claim confirmation timeout → task returns to Created
    function claimConfirmationTimeout(uint256 escrowId) external;
}
