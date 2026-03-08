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
import {IClawPactTipJar} from "./interfaces/IClawPactTipJar.sol";
import {
    IClawPactReputationRegistry
} from "./interfaces/IClawPactReputationRegistry.sol";
import {IClawPactTreasury} from "./interfaces/IClawPactTreasury.sol";

/// @title ClawPactTipJar
/// @notice On-chain tipping for ClawPact social layer (Tavern + Knowledge Mesh)
/// @dev Push model — tips transfer instantly via USDC transferFrom (no custody).
///      Platform EIP-712 signature prevents bypassing backend validation (rate limits,
///      self-tip prevention, content existence checks, etc.).
///
///      Key features:
///      - Per-address lifetime tipping stats (totalSent, totalReceived, counts)
///      - Configurable max single tip amount
///      - Configurable daily tip cap per tipper address (resets at UTC midnight)
///      - Configurable platform fee (default 5%, max 10%)
///      - Pause/unpause for emergency
///      - UUPS upgradeable for future extensions (bounty, arena, staking rewards)
///
///      Design principle: Contract NEVER holds user funds. All tips are direct
///      tipper → recipient transfers. Only platform fees accumulate in treasury.
contract ClawPactTipJar is
    IClawPactTipJar,
    UUPSUpgradeable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ========================= Constants =========================

    /// @notice EIP-712 typehash for tip authorization
    bytes32 public constant TIP_TYPEHASH =
        keccak256(
            "Tip(address tipper,address recipient,uint256 amount,string postId,uint256 nonce,uint256 expiredAt)"
        );

    /// @notice Maximum allowed platform fee: 10% = 1000 bps
    uint16 public constant MAX_FEE_BPS = 1000;

    /// @notice Minimum tip amount: 0.01 USDC (10000 = 6 decimals)
    uint256 public constant MIN_TIP_AMOUNT = 10_000;

    // ========================= Storage =========================

    /// @notice USDC token address
    IERC20 public usdcToken;

    /// @notice Platform signer address (signs EIP-712 tip authorizations)
    address public platformSigner;

    /// @notice Platform treasury address (receives fees)
    address public treasury;

    /// @notice Platform fee in basis points (500 = 5%)
    uint16 public platformFeeBps;

    /// @notice Maximum single tip amount in USDC (6 decimals)
    ///         0 = unlimited
    uint256 public maxTipAmount;

    /// @notice Maximum total tip amount per address per day in USDC (6 decimals)
    ///         0 = unlimited
    uint256 public dailyTipCap;

    /// @notice Whether tipping is paused
    bool public paused;

    /// @notice Per-address tipping statistics
    mapping(address => TipStats) private _tipStats;

    /// @notice Used nonces — keccak256(tipper, nonce) => used
    ///         Using tipper-scoped nonces to prevent cross-user replay attacks
    mapping(bytes32 => bool) private _usedNonces;

    /// @notice Daily tip tracking: keccak256(tipper, dayTimestamp) => amount spent
    mapping(bytes32 => uint256) private _dailySpent;

    /// @notice ERC-8004 Reputation Registry to send feedback
    IClawPactReputationRegistry public reputationRegistry;

    /// @notice Treasury contract for platform fee distribution (optional buyback)
    IClawPactTreasury public treasuryContract;

    /// @notice Storage gap for future upgrades
    uint256[38] private __gap;

    // ========================= Errors =========================

    error TippingPausedError();
    error SelfTipNotAllowed();
    error ZeroAddress();
    error ZeroAmount();
    error BelowMinTip();
    error ExceedsMaxTip();
    error ExceedsDailyCap();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error InvalidSignature();
    error FeeTooHigh();
    error InsufficientAllowance();

    // ========================= Initializer =========================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the TipJar contract (called once via proxy)
    /// @param _usdc USDC token address on Base
    /// @param _platformSigner Address that signs EIP-712 tip authorizations
    /// @param _treasury Platform treasury address (receives 5% fee)
    /// @param _owner Contract owner (can upgrade + configure)
    function initialize(
        address _usdc,
        address _platformSigner,
        address _treasury,
        address _owner
    ) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_platformSigner == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __EIP712_init("ClawPactTipJar", "1");

        usdcToken = IERC20(_usdc);
        platformSigner = _platformSigner;
        treasury = _treasury;
        platformFeeBps = 500; // 5% default

        // Sensible defaults — can be updated by owner post-deploy
        maxTipAmount = 1_000 * 1e6; // Max 1000 USDC per tip
        dailyTipCap = 5_000 * 1e6; // Max 5000 USDC per day per address
    }

    // ========================= Core Functions =========================

    /// @inheritdoc IClawPactTipJar
    function tip(
        address recipient,
        uint256 amount,
        string calldata postId,
        uint256 nonce,
        uint256 expiredAt,
        bytes calldata platformSignature
    ) external nonReentrant {
        // ── Guards ──
        if (paused) revert TippingPausedError();
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == msg.sender) revert SelfTipNotAllowed();
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_TIP_AMOUNT) revert BelowMinTip();
        if (maxTipAmount > 0 && amount > maxTipAmount) revert ExceedsMaxTip();
        if (block.timestamp > expiredAt) revert SignatureExpired();

        // ── Nonce check (tipper-scoped) ──
        bytes32 nonceHash = keccak256(abi.encodePacked(msg.sender, nonce));
        if (_usedNonces[nonceHash]) revert NonceAlreadyUsed();
        _usedNonces[nonceHash] = true;

        // ── Daily cap check ──
        if (dailyTipCap > 0) {
            bytes32 dayKey = _dailyKey(msg.sender);
            uint256 spent = _dailySpent[dayKey];
            if (spent + amount > dailyTipCap) revert ExceedsDailyCap();
            _dailySpent[dayKey] = spent + amount;
        }

        // ── Verify EIP-712 platform signature ──
        bytes32 structHash = keccak256(
            abi.encode(
                TIP_TYPEHASH,
                msg.sender,
                recipient,
                amount,
                keccak256(bytes(postId)),
                nonce,
                expiredAt
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, platformSignature);
        if (signer != platformSigner) revert InvalidSignature();

        // ── Calculate fee ──
        uint256 fee = (amount * platformFeeBps) / 10_000;
        uint256 recipientAmount = amount - fee;

        // ── Transfer: tipper → recipient (net) + tipper → treasury (fee) ──
        usdcToken.safeTransferFrom(msg.sender, recipient, recipientAmount);
        if (fee > 0) {
            if (address(treasuryContract) != address(0)) {
                // Route fee through Treasury (supports auto-buyback)
                usdcToken.safeTransferFrom(
                    msg.sender,
                    address(treasuryContract),
                    fee
                );
                try
                    treasuryContract.receiveFee(address(usdcToken), fee)
                {} catch {}
            } else {
                usdcToken.safeTransferFrom(msg.sender, treasury, fee);
            }
        }

        // ── Update stats ──
        TipStats storage senderStats = _tipStats[msg.sender];
        senderStats.totalSent += amount;
        senderStats.totalFeesPaid += fee;
        senderStats.tipsSentCount++;

        TipStats storage recipientStats = _tipStats[recipient];
        recipientStats.totalReceived += recipientAmount;
        recipientStats.tipsReceivedCount++;

        // ── ERC-8004 Hook ──
        if (address(reputationRegistry) != address(0)) {
            // Using tip amount (in micro-USDC) as the score to indicate strength of support
            int256 score = int256(amount);
            try
                reputationRegistry.recordAttestation(
                    recipient,
                    "TIP_RECEIVED",
                    score,
                    postId // IPFS hash or Post ID reference
                )
            {} catch {} // gracefully fail to avoid blocking funds
        }

        // ── Emit event ──
        emit TipSent(msg.sender, recipient, amount, fee, postId);
    }

    // ========================= View Functions =========================

    /// @inheritdoc IClawPactTipJar
    function tipStats(address user) external view returns (TipStats memory) {
        return _tipStats[user];
    }

    /// @inheritdoc IClawPactTipJar
    function dailyTipSpent(address user) external view returns (uint256) {
        return _dailySpent[_dailyKey(user)];
    }

    /// @inheritdoc IClawPactTipJar
    function usedNonces(bytes32 nonceHash) external view returns (bool) {
        return _usedNonces[nonceHash];
    }

    /// @notice Check if a specific tipper+nonce combination has been used
    function isNonceUsed(
        address tipper,
        uint256 nonce
    ) external view returns (bool) {
        return _usedNonces[keccak256(abi.encodePacked(tipper, nonce))];
    }

    /// @notice Get the EIP-712 domain separator (useful for SDK integration)
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ========================= Admin Functions =========================

    /// @inheritdoc IClawPactTipJar
    function setPlatformFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint16 old = platformFeeBps;
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(old, newFeeBps);
    }

    /// @inheritdoc IClawPactTipJar
    function setMaxTipAmount(uint256 newMax) external onlyOwner {
        uint256 old = maxTipAmount;
        maxTipAmount = newMax;
        emit MaxTipAmountUpdated(old, newMax);
    }

    /// @inheritdoc IClawPactTipJar
    function setDailyTipCap(uint256 newCap) external onlyOwner {
        uint256 old = dailyTipCap;
        dailyTipCap = newCap;
        emit DailyTipCapUpdated(old, newCap);
    }

    /// @inheritdoc IClawPactTipJar
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit TippingPaused(_paused);
    }

    /// @inheritdoc IClawPactTipJar
    function setPlatformSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        address old = platformSigner;
        platformSigner = newSigner;
        emit PlatformSignerUpdated(old, newSigner);
    }

    /// @inheritdoc IClawPactTipJar
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    /// @notice Hook up the external ERC-8004 Reputation registry
    function setReputationRegistry(address registry) external onlyOwner {
        reputationRegistry = IClawPactReputationRegistry(registry);
    }

    /// @notice Set the Treasury contract for platform fee distribution
    function setTreasuryContract(address _treasury) external onlyOwner {
        treasuryContract = IClawPactTreasury(_treasury);
    }

    // ========================= Internal Functions =========================

    /// @notice Generate a daily-reset key for tip cap tracking
    /// @dev Uses UTC day boundary: block.timestamp / 86400 * 86400
    function _dailyKey(address user) internal view returns (bytes32) {
        uint256 dayTimestamp = (block.timestamp / 86400) * 86400;
        return keccak256(abi.encodePacked(user, dayTimestamp));
    }

    /// @notice UUPS upgrade authorization — only owner
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
