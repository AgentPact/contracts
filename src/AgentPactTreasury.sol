// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentPactTreasury} from "./interfaces/IAgentPactTreasury.sol";

/// @notice Minimal interface for Uniswap V3 SwapRouter exactInputSingle
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

/// @notice Minimal interface for Uniswap V3 QuoterV2
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(
        QuoteExactInputSingleParams calldata params
    )
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}

/// @notice Minimal interface for WETH deposit/withdraw
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title AgentPactTreasury
/// @notice Platform fee distribution with optional Uniswap V3 auto-buyback
/// @dev Receives fees from Escrow & TipJar, optionally swaps a portion for a
///      target token via Uniswap V3. Both the bought token and remaining fees
///      are forwarded to the platform wallet. Contract NEVER holds permanent funds.
///
///      Key features:
///      - Configurable buyback ratio (buybackBps)
///      - Configurable target token, pool fee, and max slippage
///      - Graceful fallback: if swap fails, forward original token to wallet
///      - Support for both ETH and ERC20 payment tokens
///      - UUPS upgradeable for future extensions
contract AgentPactTreasury is
    IAgentPactTreasury,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    event SwapQuoterUpdated(address oldQuoter, address newQuoter);

    // ========================= Constants =========================

    /// @notice Maximum buyback ratio: 100% = 10000 bps
    uint16 public constant MAX_BUYBACK_BPS = 10_000;

    /// @notice Maximum slippage tolerance: 20% = 2000 bps
    uint16 public constant MAX_SLIPPAGE_BPS = 2_000;

    // ========================= Storage =========================

    /// @notice Final destination wallet for all platform income (Gnosis Safe)
    address public platformWallet;

    /// @notice Master switch for auto-buyback
    bool public buybackEnabled;

    /// @notice Portion of fee routed to Uniswap swap (bps, e.g., 5000 = 50%)
    uint16 public buybackBps;

    /// @notice Token to purchase via Uniswap
    address public buybackToken;

    /// @notice Uniswap V3 SwapRouter address
    ISwapRouter public swapRouter;

    /// @notice Uniswap QuoterV2 address used to derive a protected minOut
    IQuoterV2 public swapQuoter;

    /// @notice Uniswap pool fee tier (3000 = 0.3%, 10000 = 1%)
    uint24 public swapPoolFee;

    /// @notice Maximum allowed slippage in bps (500 = 5%)
    uint16 public maxSlippageBps;

    /// @notice WETH address (needed for ETH → token swaps)
    address public weth;

    /// @notice Authorized fee senders (Escrow, TipJar contracts)
    mapping(address => bool) public authorizedCallers;

    /// @notice Storage gap for future upgrades
    uint256[39] private __gap;

    // ========================= Errors =========================

    error UnauthorizedCaller();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidBuybackBps();
    error InvalidSlippageBps();
    error InsufficientBalance();

    // ========================= Initializer =========================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Treasury contract
    /// @param _platformWallet Final destination for fees
    /// @param _weth WETH address on this chain
    /// @param _owner Contract owner
    function initialize(
        address _platformWallet,
        address _weth,
        address _owner
    ) external initializer {
        if (_platformWallet == address(0)) revert ZeroAddress();
        if (_weth == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);

        platformWallet = _platformWallet;
        weth = _weth;

        // Defaults: buyback disabled
        buybackEnabled = false;
        buybackBps = 5000; // 50% when enabled
        swapPoolFee = 3000; // 0.3% (standard)
        maxSlippageBps = 500; // 5%
    }

    // ========================= Core =========================

    /// @inheritdoc IAgentPactTreasury
    function receiveFee(address token, uint256 amount) external nonReentrant {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        if (amount == 0) revert ZeroAmount();

        emit FeeReceived(token, amount, msg.sender);

        // ── Buyback disabled or not configured → forward everything ──
        if (
            !buybackEnabled ||
            buybackBps == 0 ||
            buybackToken == address(0) ||
            address(swapRouter) == address(0) ||
            address(swapQuoter) == address(0)
        ) {
            _forwardToWallet(token, amount);
            return;
        }

        // ── Split: keep portion + swap portion ──
        uint256 swapAmount = (amount * buybackBps) / 10_000;
        uint256 keepAmount = amount - swapAmount;

        // Forward keep portion
        if (keepAmount > 0) {
            _forwardToWallet(token, keepAmount);
        }

        // Swap and forward
        if (swapAmount > 0) {
            _swapAndForward(token, swapAmount);
        }
    }

    // ========================= Internal =========================

    /// @dev Forward token or ETH to platformWallet
    function _forwardToWallet(address token, uint256 amount) internal {
        if (token == address(0)) {
            (bool success, ) = platformWallet.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(platformWallet, amount);
        }
    }

    /// @dev Swap via Uniswap V3 and send bought token to platformWallet
    ///      Falls back to forwarding original token if swap fails
    function _swapAndForward(address token, uint256 amountIn) internal {
        if (token == address(0)) {
            _swapETHForToken(amountIn);
        } else {
            _swapERC20ForToken(token, amountIn);
        }
    }

    /// @dev Swap ETH → buybackToken via WETH intermediary
    function _swapETHForToken(uint256 amountIn) internal {
        // Wrap ETH → WETH first
        try IWETH(weth).deposit{value: amountIn}() {
            IWETH(weth).approve(address(swapRouter), amountIn);
            uint256 minOut;

            try
                swapQuoter.quoteExactInputSingle(
                    IQuoterV2.QuoteExactInputSingleParams({
                        tokenIn: weth,
                        tokenOut: buybackToken,
                        amountIn: amountIn,
                        fee: swapPoolFee,
                        sqrtPriceLimitX96: 0
                    })
                )
            returns (uint256 quotedOut, uint160, uint32, uint256) {
                minOut = (quotedOut * (10_000 - maxSlippageBps)) / 10_000;
            } catch {
                IERC20(weth).safeTransfer(platformWallet, amountIn);
                emit BuybackFailed(address(0), amountIn, "quote_failed");
                return;
            }

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: buybackToken,
                    fee: swapPoolFee,
                    recipient: platformWallet,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                });

            try swapRouter.exactInputSingle(params) returns (
                uint256 amountOut
            ) {
                emit BuybackExecuted(weth, buybackToken, amountIn, amountOut);
            } catch {
                // Swap failed → unwrap WETH and send ETH to wallet
                // Since WETH is already wrapped, just transfer WETH to wallet
                IERC20(weth).safeTransfer(platformWallet, amountIn);
                emit BuybackFailed(address(0), amountIn, "swap_failed");
            }
        } catch {
            // WETH deposit failed → send raw ETH to wallet
            (bool success, ) = platformWallet.call{value: amountIn}("");
            require(success, "ETH fallback failed");
            emit BuybackFailed(address(0), amountIn, "weth_deposit_failed");
        }
    }

    /// @dev Swap ERC20 → buybackToken
    function _swapERC20ForToken(address tokenIn, uint256 amountIn) internal {
        IERC20(tokenIn).approve(address(swapRouter), amountIn);
        uint256 minOut;

        try
            swapQuoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: buybackToken,
                    amountIn: amountIn,
                    fee: swapPoolFee,
                    sqrtPriceLimitX96: 0
                })
            )
        returns (uint256 quotedOut, uint160, uint32, uint256) {
            minOut = (quotedOut * (10_000 - maxSlippageBps)) / 10_000;
        } catch {
            IERC20(tokenIn).safeTransfer(platformWallet, amountIn);
            emit BuybackFailed(tokenIn, amountIn, "quote_failed");
            return;
        }

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: buybackToken,
                fee: swapPoolFee,
                recipient: platformWallet,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            });

        try swapRouter.exactInputSingle(params) returns (uint256 amountOut) {
            emit BuybackExecuted(tokenIn, buybackToken, amountIn, amountOut);
        } catch {
            // Swap failed → forward original token to wallet
            IERC20(tokenIn).safeTransfer(platformWallet, amountIn);
            emit BuybackFailed(tokenIn, amountIn, "swap_failed");
        }
    }

    // ========================= Admin =========================

    /// @notice Configure buyback parameters in one call
    function setBuybackConfig(
        bool _enabled,
        uint16 _buybackBps,
        address _buybackToken,
        uint24 _poolFee,
        uint16 _maxSlippageBps
    ) external onlyOwner {
        if (_buybackBps > MAX_BUYBACK_BPS) revert InvalidBuybackBps();
        if (_maxSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidSlippageBps();

        buybackEnabled = _enabled;
        buybackBps = _buybackBps;
        buybackToken = _buybackToken;
        swapPoolFee = _poolFee;
        maxSlippageBps = _maxSlippageBps;

        emit BuybackConfigUpdated(
            _enabled,
            _buybackBps,
            _buybackToken,
            _poolFee,
            _maxSlippageBps
        );
    }

    /// @notice Update the Uniswap V3 SwapRouter address
    function setSwapRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        address old = address(swapRouter);
        swapRouter = ISwapRouter(_router);
        emit SwapRouterUpdated(old, _router);
    }

    /// @notice Update the Uniswap QuoterV2 address
    function setSwapQuoter(address _quoter) external onlyOwner {
        if (_quoter == address(0)) revert ZeroAddress();
        address old = address(swapQuoter);
        swapQuoter = IQuoterV2(_quoter);
        emit SwapQuoterUpdated(old, _quoter);
    }

    /// @notice Update the platform wallet (final fee destination)
    function setPlatformWallet(address _wallet) external onlyOwner {
        if (_wallet == address(0)) revert ZeroAddress();
        address old = platformWallet;
        platformWallet = _wallet;
        emit PlatformWalletUpdated(old, _wallet);
    }

    /// @notice Authorize or revoke a fee sender (Escrow, TipJar)
    function setAuthorizedCaller(
        address caller,
        bool status
    ) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCallers[caller] = status;
        emit CallerAuthorized(caller, status);
    }

    /// @notice Emergency withdraw stuck funds
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = owner().call{value: amount}("");
            require(success, "ETH withdraw failed");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }

    // ========================= UUPS =========================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /// @dev Allow contract to receive ETH
    receive() external payable {}
}
