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
import {IClawPactEscrow} from "./interfaces/IClawPactEscrow.sol";

/// @title ClawPactEscrowV2
/// @notice Trustless escrow for AI agent task marketplace
/// @dev UUPS upgradeable. Platform NEVER touches on-chain funds. Only requester & provider operate.
contract ClawPactEscrowV2 is
    IClawPactEscrow,
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

    /// @notice Platform fee rate in basis points (300 = 3%)
    uint256 public constant PLATFORM_FEE_BPS = 300;

    /// @notice Minimum passRate floor to protect provider (30%)
    uint8 public constant MIN_PASS_RATE = 30;

    /// @notice Confirmation window duration
    uint64 public constant CONFIRMATION_WINDOW = 2 hours;

    // ========================= Storage =========================

    /// @notice Auto-incrementing escrow ID counter
    uint256 public nextEscrowId;

    /// @notice Platform signer address (signs EIP-712 assignment, managed via HSM)
    address public platformSigner;

    /// @notice Platform fund address (receives fees, managed via Gnosis Safe)
    address public platformFund;

    /// @notice Escrow records: escrowId => EscrowRecord
    mapping(uint256 => EscrowRecord) public escrows;

    /// @notice Assignment nonces: escrowId => nonce (prevents replay, increments on claim/decline)
    mapping(uint256 => uint256) public assignmentNonces;

    /// @notice Calculated pass rates: escrowId => passRate (submitted by platform off-chain)
    mapping(uint256 => uint8) public calculatedPassRates;

    /// @notice Allowed ERC20 tokens for payment (e.g. USDC)
    mapping(address => bool) public allowedTokens;

    /// @notice Storage gap for future upgrades
    uint256[43] private __gap;

    // ========================= Errors =========================

    error InvalidState(TaskState current, TaskState expected);
    error OnlyRequester();
    error OnlyProvider();
    error OnlyParties();
    error SignatureExpired();
    error InvalidNonce();
    error InvalidSignature();
    error InvalidMaxRevisions();
    error InvalidDeadline();
    error InvalidAcceptanceWindow();
    error InsufficientDeposit();
    error DeadlineNotReached();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPassRate();
    error TokenNotAllowed();

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
        __EIP712_init("ClawPact", "2");

        platformSigner = _platformSigner;
        platformFund = _platformFund;
        nextEscrowId = 1;
    }

    // ========================= Requester Functions =========================

    /// @inheritdoc IClawPactEscrow
    function createEscrow(
        bytes32 taskHash,
        uint64 deliveryDeadline,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours
    ) external payable nonReentrant returns (uint256 escrowId) {
        if (deliveryDeadline <= block.timestamp) revert InvalidDeadline();
        if (maxRevisions < 1 || maxRevisions > 10) revert InvalidMaxRevisions();
        if (acceptanceWindowHours < 12 || acceptanceWindowHours > 168)
            revert InvalidAcceptanceWindow();
        if (msg.value == 0) revert ZeroAmount();

        // Calculate deposit based on maxRevisions
        uint256 depositRate = _depositRate(maxRevisions);
        uint256 totalRequired = msg.value;
        // reward = total / (100 + depositRate) * 100
        uint256 rewardAmount = (totalRequired * 100) / (100 + depositRate);
        uint256 requesterDeposit = totalRequired - rewardAmount;

        escrowId = nextEscrowId++;

        EscrowRecord storage r = escrows[escrowId];
        r.requester = msg.sender;
        r.rewardAmount = rewardAmount;
        r.requesterDeposit = requesterDeposit;
        r.token = address(0); // native ETH for MVP
        r.state = TaskState.Created;
        r.taskHash = taskHash;
        r.deliveryDeadline = deliveryDeadline;
        r.maxRevisions = maxRevisions;
        r.acceptanceWindowHours = acceptanceWindowHours;

        emit EscrowCreated(
            escrowId,
            msg.sender,
            taskHash,
            rewardAmount,
            requesterDeposit,
            address(0),
            deliveryDeadline,
            maxRevisions,
            acceptanceWindowHours
        );
    }

    /// @notice Create a new escrow using ERC20 token (e.g. USDC)
    /// @param token The ERC20 token address (must be in allowedTokens whitelist)
    /// @param totalAmount Total amount to deposit (reward + deposit auto-calculated)
    function createEscrowERC20(
        bytes32 taskHash,
        uint64 deliveryDeadline,
        uint8 maxRevisions,
        uint8 acceptanceWindowHours,
        address token,
        uint256 totalAmount
    ) external nonReentrant returns (uint256 escrowId) {
        if (deliveryDeadline <= block.timestamp) revert InvalidDeadline();
        if (maxRevisions < 1 || maxRevisions > 10) revert InvalidMaxRevisions();
        if (acceptanceWindowHours < 12 || acceptanceWindowHours > 168)
            revert InvalidAcceptanceWindow();
        if (totalAmount == 0) revert ZeroAmount();
        if (!allowedTokens[token]) revert TokenNotAllowed();

        // Transfer tokens from requester to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

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
        r.deliveryDeadline = deliveryDeadline;
        r.maxRevisions = maxRevisions;
        r.acceptanceWindowHours = acceptanceWindowHours;

        emit EscrowCreated(
            escrowId,
            msg.sender,
            taskHash,
            rewardAmount,
            requesterDeposit,
            token,
            deliveryDeadline,
            maxRevisions,
            acceptanceWindowHours
        );
    }

    /// @inheritdoc IClawPactEscrow
    function acceptDelivery(
        uint256 escrowId
    )
        external
        nonReentrant
        onlyRequester(escrowId)
        inState(escrowId, TaskState.Delivered)
    {
        EscrowRecord storage r = escrows[escrowId];

        uint256 fee = (r.rewardAmount * PLATFORM_FEE_BPS) / 10_000;
        uint256 providerPayout = r.rewardAmount - fee;

        // Return remaining deposit to requester
        uint256 remainingDeposit = r.requesterDeposit - r.depositConsumed;

        r.state = TaskState.Accepted;

        _transfer(r.token, r.provider, providerPayout);
        _transfer(r.token, platformFund, fee);
        if (remainingDeposit > 0) {
            _transfer(r.token, r.requester, remainingDeposit);
        }

        emit DeliveryAccepted(escrowId, providerPayout, fee);
    }

    /// @inheritdoc IClawPactEscrow
    function requestRevision(
        uint256 escrowId,
        bytes32 reasonHash,
        bytes32 criteriaResultsHash
    )
        external
        nonReentrant
        onlyRequester(escrowId)
        inState(escrowId, TaskState.Delivered)
    {
        EscrowRecord storage r = escrows[escrowId];

        // Progressive deposit penalty (skip first revision)
        uint256 penalty = 0;
        if (r.currentRevision > 0) {
            penalty = _calcPenalty(r);
            if (penalty > 0) {
                r.depositConsumed += penalty;
                // 50% to provider, 50% to platform fund
                _transfer(r.token, r.provider, penalty / 2);
                _transfer(r.token, platformFund, penalty - penalty / 2); // handles odd wei
            }
        }

        r.currentRevision++;
        r.latestCriteriaHash = criteriaResultsHash;

        emit RevisionRequested(
            escrowId,
            reasonHash,
            criteriaResultsHash,
            r.currentRevision,
            penalty
        );

        // Auto-settle if revision limit reached
        if (r.currentRevision >= r.maxRevisions) {
            _autoSettle(escrowId);
        } else {
            r.state = TaskState.InRevision;
        }
    }

    /// @inheritdoc IClawPactEscrow
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

        r.state = TaskState.Cancelled;

        // Full refund to requester
        _transfer(r.token, r.requester, r.rewardAmount + r.requesterDeposit);

        emit TaskCancelled(escrowId);
    }

    // ========================= Provider Functions =========================

    /// @inheritdoc IClawPactEscrow
    function claimTask(
        uint256 escrowId,
        uint256 nonce,
        uint256 expiredAt,
        bytes calldata platformSignature
    ) external nonReentrant inState(escrowId, TaskState.Created) {
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

    /// @inheritdoc IClawPactEscrow
    function confirmTask(
        uint256 escrowId
    )
        external
        onlyProvider(escrowId)
        inState(escrowId, TaskState.ConfirmationPending)
    {
        escrows[escrowId].state = TaskState.Working;
        emit TaskConfirmed(escrowId, msg.sender);
    }

    /// @inheritdoc IClawPactEscrow
    function declineTask(
        uint256 escrowId
    )
        external
        onlyProvider(escrowId)
        inState(escrowId, TaskState.ConfirmationPending)
    {
        EscrowRecord storage r = escrows[escrowId];
        address previousProvider = r.provider;

        // No penalty — task returns to Created for next agent
        r.provider = address(0);
        r.state = TaskState.Created;
        r.confirmationDeadline = 0;

        emit TaskDeclined(escrowId, previousProvider);
    }

    /// @inheritdoc IClawPactEscrow
    function submitDelivery(
        uint256 escrowId,
        bytes32 deliveryHash
    ) external onlyProvider(escrowId) {
        EscrowRecord storage r = escrows[escrowId];
        if (r.state != TaskState.Working && r.state != TaskState.InRevision) {
            revert InvalidState(r.state, TaskState.Working);
        }

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

    // ========================= Timeout Functions =========================

    /// @inheritdoc IClawPactEscrow
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
        uint256 fee = (r.rewardAmount * PLATFORM_FEE_BPS) / 10_000;
        _transfer(r.token, r.provider, r.rewardAmount - fee);
        _transfer(r.token, platformFund, fee);

        // Return remaining deposit to requester
        uint256 remainingDeposit = r.requesterDeposit - r.depositConsumed;
        if (remainingDeposit > 0) {
            _transfer(r.token, r.requester, remainingDeposit);
        }

        emit TimeoutClaimed(escrowId, previousState, msg.sender);
    }

    /// @inheritdoc IClawPactEscrow
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

        // Full refund to requester
        _transfer(
            r.token,
            r.requester,
            r.rewardAmount + r.requesterDeposit - r.depositConsumed
        );

        emit TimeoutClaimed(escrowId, previousState, msg.sender);
    }

    /// @inheritdoc IClawPactEscrow
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

    /// @notice Submit calculated passRate for an escrow (called before auto-settlement)
    /// @dev Only callable by platform signer, used when requester triggers final requestRevision
    function submitPassRate(uint256 escrowId, uint8 passRate) external {
        if (msg.sender != platformSigner) revert InvalidSignature();
        if (passRate > 100) revert InvalidPassRate();
        calculatedPassRates[escrowId] = passRate;
        emit PassRateSubmitted(escrowId, passRate);
    }

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

    // ========================= View Functions =========================

    /// @notice Get full escrow record
    function getEscrow(
        uint256 escrowId
    ) external view returns (EscrowRecord memory) {
        return escrows[escrowId];
    }

    /// @notice Get the EIP-712 domain separator
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ========================= Internal Functions =========================

    /// @dev Auto-settle when revision limit is reached
    function _autoSettle(uint256 escrowId) internal {
        EscrowRecord storage r = escrows[escrowId];

        uint8 passRate = calculatedPassRates[escrowId];
        // Protection: if passRate is 0 (requester marked all fail), floor at MIN_PASS_RATE
        if (passRate < MIN_PASS_RATE) passRate = MIN_PASS_RATE;
        if (passRate > 100) passRate = 100;

        uint256 providerShare = (r.rewardAmount * passRate) / 100;
        uint256 requesterRefund = r.rewardAmount - providerShare;
        uint256 fee = (providerShare * PLATFORM_FEE_BPS) / 10_000;

        r.state = TaskState.Settled;

        _transfer(r.token, r.provider, providerShare - fee);
        _transfer(r.token, platformFund, fee);
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
            providerShare - fee,
            requesterRefund,
            fee
        );
    }

    /// @dev Calculate deposit rate based on maxRevisions
    ///      maxRevisions 1-3 → 5%, 4-5 → 8%, 6-7 → 12%, 8+ → 15%
    function _depositRate(uint8 maxRevisions) internal pure returns (uint256) {
        if (maxRevisions <= 3) return 5;
        if (maxRevisions <= 5) return 8;
        if (maxRevisions <= 7) return 12;
        return 15;
    }

    /// @dev Calculate progressive penalty for current revision round
    ///      Round 2: 10%, Round 3: 20%, Round 4: 30%, Round 5+: 40%
    function _calcPenalty(
        EscrowRecord storage r
    ) internal view returns (uint256) {
        uint256 penaltyRate;
        uint8 rev = r.currentRevision; // 0-indexed, represents completed revisions

        if (rev == 1) penaltyRate = 10;
        else if (rev == 2) penaltyRate = 20;
        else if (rev == 3) penaltyRate = 30;
        else penaltyRate = 40;

        uint256 penalty = (r.requesterDeposit * penaltyRate) / 100;

        // Cap at remaining deposit
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

    /// @dev Required by UUPS — only owner can authorize upgrades
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /// @dev Allow contract to receive ETH
    receive() external payable {}
}
