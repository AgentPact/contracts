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
        Settled, // Hit revision limit → auto-settled by on-chain passRate
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
        // ✅ Fix P0-3: Store relative duration, set absolute deadline in confirmTask
        uint64 deliveryDurationSeconds; // Relative duration (seconds), set by requester
        uint64 deliveryDeadline; // Absolute deadline, set in confirmTask()
        uint64 acceptanceDeadline;
        uint64 confirmationDeadline; // Confirmation window expiry (2h)
        uint8 maxRevisions;
        uint8 currentRevision;
        uint8 criteriaCount; // ✅ Fix P0-2: Number of acceptance criteria
        uint8 declineCount; // ✅ Fix P2-8: On-chain decline tracking
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
        uint64 deliveryDeadline // ✅ Fix P1-6: emit the computed deadline
    );

    event TaskDeclined(uint256 indexed escrowId, address indexed provider);

    /// @notice Emitted when decline count reaches 3, signaling the platform to pause matching
    event TaskSuspendedAfterDeclines(
        uint256 indexed escrowId,
        uint8 declineCount
    );

    /// @notice Emitted when agent voluntarily abandons during execution
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
        uint8 passRate // ✅ Fix P0-1: include on-chain computed passRate
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
        uint256 compensation // ✅ Fix P1-5: log compensation amount (0 if Created)
    );

    // ========================= Requester Functions =========================

    /// @notice Create a new escrow with reward + deposit locked
    /// @param taskHash SHA-256 hash of the requirement confirmation document
    /// @param deliveryDurationSeconds Relative delivery duration in seconds (deadline set in confirmTask)
    /// @param maxRevisions Maximum allowed revision rounds (determines deposit %)
    /// @param acceptanceWindowHours Hours requester has to review delivery
    /// @param criteriaCount Number of acceptance criteria (3-10)
    /// @param fundWeights Fund weight for each criterion (5-40% each, must sum to 100)
    /// @param token Payment token: address(0) = native ETH, otherwise ERC20 (must be whitelisted)
    /// @param totalAmount Total amount for ERC20 mode (ignored for ETH, msg.value used instead)
    /// @return escrowId The ID of the created escrow
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

    /// @notice Accept delivery and release funds to provider
    function acceptDelivery(uint256 escrowId) external;

    /// @notice Reject delivery and request revision (progressive deposit penalty)
    /// @param reasonHash Hash of the structured revision request
    /// @param criteriaResults Per-criterion pass(true)/fail(false) array — passRate computed on-chain
    function requestRevision(
        uint256 escrowId,
        bytes32 reasonHash,
        bool[] calldata criteriaResults
    ) external;

    /// @notice Cancel task (only from Created or ConfirmationPending state)
    /// @dev ConfirmationPending cancellation deducts 10% deposit as agent compensation
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

    /// @notice Confirm task after reviewing private materials; sets deliveryDeadline
    function confirmTask(uint256 escrowId) external;

    /// @notice Decline task during confirmation window (no penalty, tracked on-chain)
    function declineTask(uint256 escrowId) external;

    /// @notice Submit delivery artifacts
    /// @param deliveryHash SHA-256 hash of delivery artifacts
    function submitDelivery(uint256 escrowId, bytes32 deliveryHash) external;

    /// @notice Voluntarily abandon task during execution (lighter penalty than timeout)
    function abandonTask(uint256 escrowId) external;

    // ========================= Timeout Functions (Both Parties) =========================

    /// @notice Claim acceptance timeout → provider gets full reward
    function claimAcceptanceTimeout(uint256 escrowId) external;

    /// @notice Claim delivery timeout → requester gets full refund
    function claimDeliveryTimeout(uint256 escrowId) external;

    /// @notice Claim confirmation timeout → task returns to Created
    function claimConfirmationTimeout(uint256 escrowId) external;
}
