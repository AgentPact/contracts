// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IClawPactTipJar
/// @notice Interface for the ClawPact on-chain tipping contract
/// @dev Push model — tips transfer instantly from tipper to recipient (no custody).
///      Platform EIP-712 signature required to prevent bypassing backend rate limits.
interface IClawPactTipJar {
    // ========================= Structs =========================

    /// @notice Accumulated tipping statistics per address
    struct TipStats {
        uint256 totalSent; // Total USDC sent (gross, before fees)
        uint256 totalReceived; // Total USDC received (net, after fees)
        uint256 totalFeesPaid; // Total platform fees paid as tipper
        uint64 tipsSentCount; // Number of tips sent
        uint64 tipsReceivedCount; // Number of tips received
    }

    // ========================= Events =========================

    /// @notice Emitted when a tip is successfully transferred
    event TipSent(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        string postId
    );

    /// @notice Emitted when the platform fee rate is updated
    event PlatformFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);

    /// @notice Emitted when the maximum tip amount is updated
    event MaxTipAmountUpdated(uint256 oldMax, uint256 newMax);

    /// @notice Emitted when the daily tip cap per address is updated
    event DailyTipCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the contract is paused or unpaused
    event TippingPaused(bool paused);

    /// @notice Emitted when the platform signer is updated
    event PlatformSignerUpdated(address oldSigner, address newSigner);

    /// @notice Emitted when the treasury address is updated
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    // ========================= Core Functions =========================

    /// @notice Send a tip with platform signature authorization
    /// @param recipient Address receiving the tip
    /// @param amount USDC amount (6 decimals, e.g. 1000000 = 1 USDC)
    /// @param postId Social post UUID for on-chain audit trail
    /// @param nonce Anti-replay nonce (must not have been used before)
    /// @param expiredAt Signature expiry timestamp
    /// @param platformSignature EIP-712 signature from platform signer
    function tip(
        address recipient,
        uint256 amount,
        string calldata postId,
        uint256 nonce,
        uint256 expiredAt,
        bytes calldata platformSignature
    ) external;

    // ========================= View Functions =========================

    /// @notice Get tipping statistics for an address
    function tipStats(address user) external view returns (TipStats memory);

    /// @notice Check how much an address has tipped today (resets daily at UTC midnight)
    function dailyTipSpent(address user) external view returns (uint256);

    /// @notice Check if a nonce has been used
    function usedNonces(bytes32 nonceHash) external view returns (bool);

    // ========================= Admin Functions =========================

    /// @notice Update the platform fee rate (max 10% = 1000 bps)
    function setPlatformFeeBps(uint16 newFeeBps) external;

    /// @notice Update the maximum single tip amount
    function setMaxTipAmount(uint256 newMax) external;

    /// @notice Update the daily tip cap per address
    function setDailyTipCap(uint256 newCap) external;

    /// @notice Pause/unpause tipping
    function setPaused(bool paused) external;

    /// @notice Update the platform signer address
    function setPlatformSigner(address newSigner) external;

    /// @notice Update the treasury address
    function setTreasury(address newTreasury) external;

    /// @notice Update the USDC token address
    function setUsdcToken(address newUsdc) external;
}
