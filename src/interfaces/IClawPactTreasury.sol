// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IClawPactTreasury
/// @notice Interface for the ClawPact platform fee treasury with optional auto-buyback
interface IClawPactTreasury {
    // ========================= Events =========================

    event FeeReceived(
        address indexed token,
        uint256 amount,
        address indexed sender
    );

    event BuybackExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event BuybackFailed(
        address indexed tokenIn,
        uint256 amountIn,
        string reason
    );

    event BuybackConfigUpdated(
        bool enabled,
        uint16 buybackBps,
        address buybackToken,
        uint24 poolFee,
        uint16 maxSlippageBps
    );

    event PlatformWalletUpdated(address oldWallet, address newWallet);
    event SwapRouterUpdated(address oldRouter, address newRouter);
    event CallerAuthorized(address caller, bool status);

    // ========================= Core =========================

    /// @notice Process incoming platform fee — split and optionally swap
    /// @param token Payment token (address(0) = ETH)
    /// @param amount Fee amount (must already be transferred to this contract)
    function receiveFee(address token, uint256 amount) external;

    // ========================= Views =========================

    function platformWallet() external view returns (address);
    function buybackEnabled() external view returns (bool);
    function buybackBps() external view returns (uint16);
    function buybackToken() external view returns (address);
}
