// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    EIP712Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentPactEscrow} from "./interfaces/IAgentPactEscrow.sol";
import {
    IAgentPactReputationRegistry
} from "./interfaces/IAgentPactReputationRegistry.sol";
import {IAgentPactTreasury} from "./interfaces/IAgentPactTreasury.sol";

/// @title AgentPactEscrow
/// @notice Trustless escrow for AI agent task marketplace
/// @dev UUPS upgradeable. Platform NEVER touches on-chain funds. Only requester & provider operate.
///      V2.1 changes: on-chain passRate calculation, relative delivery duration, abandonTask,
///      cancelTask compensation, decline counting, revision deadline extension.
contract AgentPactEscrow is
    IAgentPactEscrow,
    UUPSUpgradeable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ========================= Constants =========================

    /// @notice EIP-712 typehash for task assignment signature
    bytes32 public constant ASSIGNMENT_TYPEHASH =
        keccak256(
            "TaskAssignment(uint256 escrowId,address agent,uint256 nonce,uint256 expiredAt)"
        );

    /// @notice Default platform fee rate in basis points (500 = 5%)
    uint16 public constant DEFAULT_PLATFORM_FEE_BPS = 500;

    /// @notice Default platform share for penalties in basis points (5000 = 50%)
    uint16 public constant DEFAULT_PENALTY_PLATFORM_BPS = 5000;

    /// @notice Maximum platform fee rate in basis points (1000 = 10%)
    uint16 public constant MAX_PLATFORM_FEE_BPS = 1000;

    /// @notice Minimum passRate floor to protect provider (30%)
    uint8 public constant MIN_PASS_RATE = 30;

    /// @notice Confirmation window duration
    uint64 public constant CONFIRMATION_WINDOW = 2 hours;

    /// @notice Maximum decline count before task is suspended
    uint8 public constant MAX_DECLINE_COUNT = 3;

    // ========================= Storage =========================

    /// @notice Auto-incrementing escrow ID counter
    uint256 public nextEscrowId;

    /// @notice Platform signer address (signs EIP-712 assignment, managed via HSM)
    address public platformSigner;

    /// @notice Platform fund address (receives fees, managed via Gnosis Safe)
    address public platformFund;

    /// @notice Escrow records: escrowId => EscrowRecord
    mapping(uint256 => EscrowRecord) public escrows;

    /// @notice Assignment nonces: escrowId => nonce (prevents replay, consumed on successful claim)
    mapping(uint256 => uint256) public assignmentNonces;

    /// @notice Fund weights per escrow: escrowId => criteriaIndex => weight (%)
    /// @dev Stored on-chain for trustless passRate calculation in _autoSettle
    mapping(uint256 => mapping(uint8 => uint8)) public escrowFundWeights;

    /// @notice Allowed ERC20 tokens for payment (e.g. USDC)
    mapping(address => bool) public allowedTokens;

    /// @notice ERC-8004 Reputation Registry to send feedback
    IAgentPactReputationRegistry public reputationRegistry;

    /// @notice Treasury contract for platform fee distribution (optional buyback)
    IAgentPactTreasury public treasuryContract;
    /// @notice Platform fee rate in basis points (500 = 5%)
    uint16 public platformFeeBps;
    /// @notice Total number of escrows that reached a terminal state
    uint256 public totalClosedEscrows;
    /// @notice Total number of escrows considered successful settlements
    uint256 public totalSuccessfulEscrows;
    /// @notice Cumulative reward volume by token for successful settlements
    mapping(address => uint256) public totalRewardVolumeByToken;
    /// @notice Cumulative provider payout volume by token for successful settlements
    mapping(address => uint256) public totalPayoutVolumeByToken;

    /// @notice Platform share for penalties in basis points (5000 = 50%)
    uint16 public penaltyPlatformBps;

    /// @notice Storage gap for future upgrades
    uint256[35] private __gap;

    // ========================= Errors =========================

    error InvalidState(TaskState current, TaskState expected);
    error OnlyRequester();
    error OnlyProvider();
    error OnlyParties();
    error SignatureExpired();
    error InvalidNonce();
    error InvalidSignature();
    error InvalidMaxRevisions();
    error InvalidAcceptanceWindow();
    error InsufficientDeposit();
    error DeadlineNotReached();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPassRate();
    error TokenNotAllowed();
    error InvalidCriteriaCount();
    error InvalidFundWeight();
    error WeightsSumNot100();
    error WeightCountMismatch();
    error InvalidDuration();
    error DeadlinePassed();
    error TaskSuspended();
    error FeeTooHigh();

    // ========================= Modifiers =========================

    modifier onlyRequester(uint256 escrowId) {
        if (msg.sender != escrows[escrowId].requester) revert OnlyRequester();
        _;
    }

    modifier onlyProvider(uint256 escrowId) {
        if (msg.sender != escrows[escrowId].provider) revert OnlyProvider();
        _;
    }

    modifier onlyParties(uint256 escrowId) {
        EscrowRecord storage r = escrows[escrowId];
        if (msg.sender != r.requester && msg.sender != r.provider)
            revert OnlyParties();
        _;
    }

    modifier inState(uint256 escrowId, TaskState expected) {
        if (escrows[escrowId].state != expected)
            revert InvalidState(escrows[escrowId].state, expected);
        _;
    }

    // ========================= Initializer =========================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (called once via proxy)
    /// @param _platformSigner Address that signs EIP-712 assignment signatures
    /// @param _platformFund Address that receives platform fees (Gnosis Safe)
    /// @param _owner Address that can upgrade the contract
    function initialize(
        address _platformSigner,
        address _platformFund,
        address _owner
    ) external initializer {
        if (_platformSigner == address(0)) revert ZeroAddress();
        if (_platformFund == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __EIP712_init("AgentPact", "2");

        platformSigner = _platformSigner;
        platformFund = _platformFund;
        platformFeeBps = DEFAULT_PLATFORM_FEE_BPS;
        penaltyPlatformBps = DEFAULT_PENALTY_PLATFORM_BPS;
        nextEscrowId = 1;
    }

    // ========================= Requester Functions =========================

    /// @inheritdoc IAgentPactEscrow
    function createEscrow(
        bytes32 taskHash,
        uint64 deliveryDurationSeconds,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours,
        uint8 criteriaCount,
        uint8[] calldata fundWeights,
        address token,
        uint256 totalAmount
    ) external payable nonReentrant returns (uint256 escrowId) {
        // 閴?Opt-1: Minimum 1 hour delivery duration
        if (deliveryDurationSeconds < 3600) revert InvalidDuration();
        if (maxRevisions < 1 || maxRevisions > 10) revert InvalidMaxRevisions();
        if (acceptanceWindowHours < 12 || acceptanceWindowHours > 168)
            revert InvalidAcceptanceWindow();

        // 閴?Fix P0-2: Validate fund weights on-chain
        if (criteriaCount < 3 || criteriaCount > 10)
            revert InvalidCriteriaCount();
        if (fundWeights.length != criteriaCount) revert WeightCountMismatch();
        uint256 totalWeight = 0;
        for (uint8 i = 0; i < criteriaCount; i++) {
            if (fundWeights[i] < 5 || fundWeights[i] > 40)
                revert InvalidFundWeight();
            totalWeight += fundWeights[i];
        }
        if (totalWeight != 100) revert WeightsSumNot100();

        // Determine payment mode by token address
        if (token == address(0)) {
            // ETH mode: use msg.value as total
            if (msg.value == 0) revert ZeroAmount();
            totalAmount = msg.value;
        } else {
            // ERC20 mode: must not attach ETH, token must be whitelisted
            require(msg.value == 0, "ETH not accepted for ERC20 escrows");
            if (totalAmount == 0) revert ZeroAmount();
            if (!allowedTokens[token]) revert TokenNotAllowed();
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                totalAmount
            );
        }

        // Calculate deposit based on maxRevisions
        uint256 depositRate = _depositRate(maxRevisions);
        uint256 rewardAmount = (totalAmount * 100) / (100 + depositRate);
        uint256 requesterDeposit = totalAmount - rewardAmount;

        escrowId = nextEscrowId++;

        EscrowRecord storage r = escrows[escrowId];
        r.requester = msg.sender;
        r.rewardAmount = rewardAmount;
        r.requesterDeposit = requesterDeposit;
        r.token = token;
        r.state = TaskState.Created;
        r.taskHash = taskHash;
        // 閴?Fix P0-3: Store relative duration, deadline set in confirmTask()
        r.deliveryDurationSeconds = deliveryDurationSeconds;
        r.deliveryDeadline = 0; // Not yet set 閳?will be set in confirmTask()
        r.maxRevisions = maxRevisions;
        r.criteriaCount = criteriaCount;
        r.acceptanceWindowHours = acceptanceWindowHours;

        // 閴?Fix P0-2: Store fund weights on-chain for passRate calculation
        for (uint8 i = 0; i < criteriaCount; i++) {
            escrowFundWeights[escrowId][i] = fundWeights[i];
        }

        emit EscrowCreated(
            escrowId,
            msg.sender,
            taskHash,
            rewardAmount,
            requesterDeposit,
            token,
            deliveryDurationSeconds,
            maxRevisions,
            acceptanceWindowHours,
            criteriaCount
        );
    }

    /// @inheritdoc IAgentPactEscrow
    function acceptDelivery(
        uint256 escrowId
    )
        external
        nonReentrant
        onlyRequester(escrowId)
        inState(escrowId, TaskState.Delivered)
    {
        EscrowRecord storage r = escrows[escrowId];

        uint256 fee = (r.rewardAmount * platformFeeBps) / 10_000;
        uint256 providerPayout = r.rewardAmount - fee;

        // Return remaining deposit to requester
        uint256 remainingDeposit = r.requesterDeposit - r.depositConsumed;

        r.state = TaskState.Accepted;
        totalClosedEscrows += 1;
        totalSuccessfulEscrows += 1;
        totalRewardVolumeByToken[r.token] += r.rewardAmount;
        totalPayoutVolumeByToken[r.token] += providerPayout;
        _transfer(r.token, r.provider, providerPayout);
        _transferPlatformFee(r.token, fee);
        if (remainingDeposit > 0) {
            _transfer(r.token, r.requester, remainingDeposit);
        }

        // --- ERC-8004 Hook ---
        if (address(reputationRegistry) != address(0)) {
            // Maximum positive score for accepted delivery
            int256 baseScore = 5;
            // Optional: convert payout to a string parameter or IPFS hash here if needed.
            try
                reputationRegistry.recordAttestation(
                    r.provider,
                    "ESCROW_ACCEPTED",
                    baseScore,
                    "ipfs://contract-auto-generated" // Placeholder for detailed breakdown
                )
            {} catch {} // gracefully fail to avoid blocking funds
        }

        emit DeliveryAccepted(escrowId, providerPayout, fee);
    }

    /// @inheritdoc IAgentPactEscrow
    function requestRevision(
        uint256 escrowId,
        bytes32 reasonHash,
        bool[] calldata criteriaResults
    )
        external
        nonReentrant
        onlyRequester(escrowId)
        inState(escrowId, TaskState.Delivered)
    {
        EscrowRecord storage r = escrows[escrowId];

        // 閴?Fix P0-1: Validate criteriaResults length matches on-chain criteriaCount
        require(
            criteriaResults.length == r.criteriaCount,
            "Criteria count mismatch"
        );

        uint8 requestedRevision = r.currentRevision + 1;

        // Progressive deposit penalty is charged for the revision being requested.
        // Round 1 is free; rounds 2+ consume requester deposit sequentially.
        uint256 penalty = 0;
        if (requestedRevision > 1) {
            penalty = _calcPenalty(r, requestedRevision);
            if (penalty > 0) {
                r.depositConsumed += penalty;
                // Distribute penalty between provider and platform
                uint256 platformShare = (penalty * penaltyPlatformBps) / 10000;
                uint256 providerShare = penalty - platformShare;

                _transfer(r.token, r.provider, providerShare);
                _transferPlatformFee(r.token, platformShare);
            }
        }

        r.currentRevision = requestedRevision;

        // 閴?Fix P0-1: Compute passRate on-chain from criteriaResults + fundWeights
        uint8 passRate = _calcPassRate(escrowId, criteriaResults);

        // Store criteria hash for off-chain reference (use abi.encode to avoid packed collision)
        r.latestCriteriaHash = keccak256(abi.encode(criteriaResults));

        emit RevisionRequested(
            escrowId,
            reasonHash,
            r.latestCriteriaHash,
            r.currentRevision,
            penalty,
            passRate
        );

        // Auto-settle only after all granted revision rounds have already been used
        if (r.currentRevision > r.maxRevisions) {
            r.currentRevision = r.maxRevisions;
            _autoSettle(escrowId, passRate);
        } else {
            r.state = TaskState.InRevision;
            // 閴?Fix P1-7: Extend delivery deadline by 50% of original duration on each revision
            r.deliveryDeadline = uint64(
                block.timestamp + r.deliveryDurationSeconds / 2
            );
        }
    }

    /// @inheritdoc IAgentPactEscrow
    function cancelTask(
        uint256 escrowId
    ) external nonReentrant onlyRequester(escrowId) {
        EscrowRecord storage r = escrows[escrowId];
        if (
            r.state != TaskState.Created &&
            r.state != TaskState.ConfirmationPending
        ) {
            revert InvalidState(r.state, TaskState.Created);
        }

        uint256 compensation = 0;

        if (r.state == TaskState.Created) {
            // Created stage: full refund to requester
            r.state = TaskState.Cancelled;
            totalClosedEscrows += 1;
            _transfer(
                r.token,
                r.requester,
                r.rewardAmount + r.requesterDeposit
            );
        } else {
            // 閴?Fix P1-5: ConfirmationPending 閳?agent has seen confidential materials
            // Deduct 10% of deposit as compensation to agent
            compensation = r.requesterDeposit / 10;
            r.depositConsumed += compensation;
            r.state = TaskState.Cancelled;
            totalClosedEscrows += 1;
            _transfer(r.token, r.provider, compensation);
            // Refund remaining to requester
            uint256 remaining = r.rewardAmount +
                r.requesterDeposit -
                compensation;
            _transfer(r.token, r.requester, remaining);
        }

        emit TaskCancelled(escrowId, compensation);
    }

    // ========================= Provider Functions =========================

    /// @inheritdoc IAgentPactEscrow
    function claimTask(
        uint256 escrowId,
        uint256 nonce,
        uint256 expiredAt,
        bytes calldata platformSignature
    ) external nonReentrant inState(escrowId, TaskState.Created) {
        if (escrows[escrowId].declineCount >= MAX_DECLINE_COUNT)
            revert TaskSuspended();
        if (block.timestamp > expiredAt) revert SignatureExpired();
        if (nonce != assignmentNonces[escrowId]) revert InvalidNonce();

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(
            abi.encode(
                ASSIGNMENT_TYPEHASH,
                escrowId,
                msg.sender,
                nonce,
                expiredAt
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, platformSignature);
        if (signer != platformSigner) revert InvalidSignature();

        // Increment nonce (old signatures automatically invalidated)
        assignmentNonces[escrowId]++;

        EscrowRecord storage r = escrows[escrowId];
        r.provider = msg.sender;
        r.state = TaskState.ConfirmationPending;
        r.confirmationDeadline = uint64(block.timestamp) + CONFIRMATION_WINDOW;

        emit TaskClaimed(escrowId, msg.sender, r.confirmationDeadline);
    }

    /// @inheritdoc IAgentPactEscrow
    function confirmTask(
        uint256 escrowId
    )
        external
        nonReentrant
        onlyProvider(escrowId)
        inState(escrowId, TaskState.ConfirmationPending)
    {
        EscrowRecord storage r = escrows[escrowId];
        if (block.timestamp > r.confirmationDeadline) revert DeadlinePassed();
        r.state = TaskState.Working;
        // 閴?Fix P1-6: Set delivery deadline from confirmation moment
        r.deliveryDeadline = uint64(
            block.timestamp + r.deliveryDurationSeconds
        );

        emit TaskConfirmed(escrowId, msg.sender, r.deliveryDeadline);
    }

    /// @inheritdoc IAgentPactEscrow
    function declineTask(
        uint256 escrowId
    )
        external
        onlyProvider(escrowId)
        inState(escrowId, TaskState.ConfirmationPending)
    {
        EscrowRecord storage r = escrows[escrowId];
        address previousProvider = r.provider;

        // No penalty 閳?task returns to Created for next agent
        r.provider = address(0);
        r.state = TaskState.Created;
        r.confirmationDeadline = 0;

        // 閴?Fix P2-8: Track decline count on-chain
        r.declineCount++;

        emit TaskDeclined(escrowId, previousProvider);

        // Suspend matching after MAX_DECLINE_COUNT declines
        if (r.declineCount >= MAX_DECLINE_COUNT) {
            emit TaskSuspendedAfterDeclines(escrowId, r.declineCount);
        }
    }

    /// @inheritdoc IAgentPactEscrow
    function submitDelivery(
        uint256 escrowId,
        bytes32 deliveryHash
    ) external onlyProvider(escrowId) {
        EscrowRecord storage r = escrows[escrowId];
        if (r.state != TaskState.Working && r.state != TaskState.InRevision) {
            revert InvalidState(r.state, TaskState.Working);
        }
        if (block.timestamp > r.deliveryDeadline) revert DeadlinePassed();

        r.latestDeliveryHash = deliveryHash;
        r.state = TaskState.Delivered;
        r.acceptanceDeadline =
            uint64(block.timestamp) +
            uint64(r.acceptanceWindowHours) *
            1 hours;

        emit DeliverySubmitted(
            escrowId,
            deliveryHash,
            r.currentRevision,
            r.acceptanceDeadline
        );
    }

    /// @inheritdoc IAgentPactEscrow
    /// @notice Agent voluntarily abandons during Working or InRevision
    function abandonTask(
        uint256 escrowId
    ) external nonReentrant onlyProvider(escrowId) {
        EscrowRecord storage r = escrows[escrowId];
        if (r.state != TaskState.Working && r.state != TaskState.InRevision) {
            revert InvalidState(r.state, TaskState.Working);
        }

        address previousProvider = r.provider;

        // Task returns to Created for re-matching 閳?reset all execution state
        r.provider = address(0);
        r.state = TaskState.Created;
        r.deliveryDeadline = 0;
        r.confirmationDeadline = 0;
        r.currentRevision = 0;
        r.latestDeliveryHash = bytes32(0);
        r.latestCriteriaHash = bytes32(0);
        // NOTE: Credit penalty (-15) is applied off-chain by Credit Service

        emit TaskAbandoned(escrowId, previousProvider);
    }

    // ========================= Timeout Functions =========================

    /// @inheritdoc IAgentPactEscrow
    function claimAcceptanceTimeout(
        uint256 escrowId
    )
        external
        nonReentrant
        onlyParties(escrowId)
        inState(escrowId, TaskState.Delivered)
    {
        EscrowRecord storage r = escrows[escrowId];
        if (block.timestamp <= r.acceptanceDeadline)
            revert DeadlineNotReached();

        TaskState previousState = r.state;
        r.state = TaskState.TimedOut;

        // Full reward to provider (requester defaulted)
        uint256 fee = (r.rewardAmount * platformFeeBps) / 10_000;
        uint256 providerPayout = r.rewardAmount - fee;
        totalClosedEscrows += 1;
        totalSuccessfulEscrows += 1;
        totalRewardVolumeByToken[r.token] += r.rewardAmount;
        totalPayoutVolumeByToken[r.token] += providerPayout;
        _transfer(r.token, r.provider, providerPayout);
        _transferPlatformFee(r.token, fee);

        // Return remaining deposit to requester
        uint256 remainingDeposit = r.requesterDeposit - r.depositConsumed;
        if (remainingDeposit > 0) {
            _transfer(r.token, r.requester, remainingDeposit);
        }

        emit TimeoutClaimed(escrowId, previousState, msg.sender);
    }

    /// @inheritdoc IAgentPactEscrow
    function claimDeliveryTimeout(
        uint256 escrowId
    ) external nonReentrant onlyParties(escrowId) {
        EscrowRecord storage r = escrows[escrowId];
        if (r.state != TaskState.Working && r.state != TaskState.InRevision) {
            revert InvalidState(r.state, TaskState.Working);
        }
        if (block.timestamp <= r.deliveryDeadline) revert DeadlineNotReached();

        TaskState previousState = r.state;
        r.state = TaskState.TimedOut;
        totalClosedEscrows += 1;
        // Full refund to requester
        _transfer(
            r.token,
            r.requester,
            r.rewardAmount + r.requesterDeposit - r.depositConsumed
        );

        emit TimeoutClaimed(escrowId, previousState, msg.sender);
    }

    /// @inheritdoc IAgentPactEscrow
    function claimConfirmationTimeout(
        uint256 escrowId
    )
        external
        onlyParties(escrowId)
        inState(escrowId, TaskState.ConfirmationPending)
    {
        EscrowRecord storage r = escrows[escrowId];
        if (block.timestamp <= r.confirmationDeadline)
            revert DeadlineNotReached();

        r.provider = address(0);
        r.state = TaskState.Created;
        r.confirmationDeadline = 0;

        emit TimeoutClaimed(
            escrowId,
            TaskState.ConfirmationPending,
            msg.sender
        );
    }

    // ========================= Admin Functions =========================

    /// @notice Add or remove an allowed ERC20 token
    function setAllowedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedTokens[token] = allowed;
    }

    /// @notice Update platform signer address (key rotation)
    function setPlatformSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        platformSigner = newSigner;
    }

    /// @notice Update platform fund address
    function setPlatformFund(address newFund) external onlyOwner {
        if (newFund == address(0)) revert ZeroAddress();
        platformFund = newFund;
    }

    /// @inheritdoc IAgentPactEscrow
    function setPlatformFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        uint16 oldFeeBps = platformFeeBps;
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(oldFeeBps, newFeeBps);
    }

    /// @notice Set the platform commission configured for penalty allocations
    function setPenaltyPlatformBps(uint16 _bps) external onlyOwner {
        if (_bps > 10000) revert FeeTooHigh();
        penaltyPlatformBps = _bps;
    }

    /// @notice Set the Treasury contract for platform fee distribution
    function setTreasury(address _treasury) external onlyOwner {
        treasuryContract = IAgentPactTreasury(_treasury);
    }

    // ========================= View Functions =========================

    /// @notice Get full escrow record
    function getEscrow(
        uint256 escrowId
    ) external view returns (EscrowRecord memory) {
        return escrows[escrowId];
    }

    /// @notice Get fund weight for a specific criterion
    function getFundWeight(
        uint256 escrowId,
        uint8 criteriaIndex
    ) external view returns (uint8) {
        return escrowFundWeights[escrowId][criteriaIndex];
    }

    /// @notice Get all fund weights for an escrow
    function getFundWeights(
        uint256 escrowId
    ) external view returns (uint8[] memory) {
        uint8 count = escrows[escrowId].criteriaCount;
        uint8[] memory weights = new uint8[](count);
        for (uint8 i = 0; i < count; i++) {
            weights[i] = escrowFundWeights[escrowId][i];
        }
        return weights;
    }

    /// @notice Get the EIP-712 domain separator
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ========================= Internal Functions =========================

    /// @dev Calculate passRate on-chain from criteriaResults and stored fundWeights
    /// @param escrowId The escrow ID (to look up stored fund weights)
    /// @param criteriaResults Per-criterion pass(true)/fail(false) array
    /// @return passRate Weighted pass rate (0-100)
    function _calcPassRate(
        uint256 escrowId,
        bool[] calldata criteriaResults
    ) internal view returns (uint8) {
        uint256 passed = 0;
        uint8 count = escrows[escrowId].criteriaCount;
        for (uint8 i = 0; i < count; i++) {
            if (criteriaResults[i]) {
                passed += escrowFundWeights[escrowId][i];
            }
        }
        // Safe cast: passed is at most 100 (sum of all weights)
        return uint8(passed);
    }

    /// @dev Auto-settle when revision limit is reached
    /// @param escrowId The escrow to settle
    /// @param passRate On-chain computed passRate from _calcPassRate
    function _autoSettle(uint256 escrowId, uint8 passRate) internal {
        EscrowRecord storage r = escrows[escrowId];

        // 閴?Fix P0-1: passRate computed on-chain, apply MIN_PASS_RATE floor
        if (passRate < MIN_PASS_RATE) passRate = MIN_PASS_RATE;
        if (passRate > 100) passRate = 100;

        uint256 providerShare = (r.rewardAmount * passRate) / 100;
        uint256 requesterRefund = r.rewardAmount - providerShare;
        uint256 fee = (providerShare * platformFeeBps) / 10_000;
        uint256 providerPayout = providerShare - fee;
        r.state = TaskState.Settled;
        totalClosedEscrows += 1;
        totalSuccessfulEscrows += 1;
        totalRewardVolumeByToken[r.token] += r.rewardAmount;
        totalPayoutVolumeByToken[r.token] += providerPayout;
        _transfer(r.token, r.provider, providerPayout);
        _transferPlatformFee(r.token, fee);
        if (requesterRefund > 0) {
            _transfer(r.token, r.requester, requesterRefund);
        }

        // Return remaining deposit to requester
        uint256 remainingDeposit = r.requesterDeposit - r.depositConsumed;
        if (remainingDeposit > 0) {
            _transfer(r.token, r.requester, remainingDeposit);
        }

        emit TaskAutoSettled(
            escrowId,
            passRate,
            providerPayout,
            requesterRefund,
            fee
        );
    }

    /// @dev Calculate deposit rate based on maxRevisions
    ///      maxRevisions 1-3 閳?5%, 4-5 閳?8%, 6-7 閳?12%, 8+ 閳?15%
    function _depositRate(uint8 maxRevisions) internal pure returns (uint256) {
        if (maxRevisions <= 3) return 5;
        if (maxRevisions <= 5) return 8;
        if (maxRevisions <= 7) return 12;
        return 15;
    }

    /// @dev Calculate progressive penalty for the revision round being requested
    ///      Using arithmetic progression arithmetic to spread the deposit smoothly across maxRevisions.
    ///      For maxRevisions = 5, equivalent to Round 2: 10%, Round 3: 20%, Round 4: 30%, Round 5: 40%
    function _calcPenalty(
        EscrowRecord storage r,
        uint8 requestedRevision
    ) internal view returns (uint256) {
        if (requestedRevision > r.maxRevisions) {
            return r.requesterDeposit - r.depositConsumed;
        }

        uint256 n = r.maxRevisions - 1;
        if (n == 0) return 0;

        uint256 i = requestedRevision - 1;

        // penalty = deposit * 2 * i / (n * (n+1))
        uint256 penalty = (uint256(r.requesterDeposit) * 2 * i) / (n * (n + 1));

        // Cap at remaining deposit to prevent rounding oversell
        uint256 remaining = r.requesterDeposit - r.depositConsumed;
        if (penalty > remaining) penalty = remaining;

        return penalty;
    }

    /// @dev Transfer ETH or ERC20 token
    function _transfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Send platform fee via Treasury contract (with optional buyback).
    ///      Falls back to direct transfer if Treasury is not configured.
    function _transferPlatformFee(address token, uint256 feeAmount) internal {
        if (address(treasuryContract) != address(0)) {
            _transfer(token, address(treasuryContract), feeAmount);
            treasuryContract.receiveFee(token, feeAmount);
        } else {
            _transfer(token, platformFund, feeAmount);
        }
    }

    /// @dev Required by UUPS 閳?only owner can authorize upgrades
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /// @dev Allow contract to receive ETH
    receive() external payable {}
}
