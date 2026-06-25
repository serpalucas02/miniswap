// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MiniSwap
 * @author Lucas Serpa
 * @notice A minimal constant-product AMM (Uniswap-V2 style) for a single pair of ERC-20s.
 *         Provide liquidity to earn LP tokens and a share of the 0.3% swap fee; swap one
 *         token for the other along the x * y = k curve.
 * @dev The contract IS its own LP token (ERC-20). Key safety choices:
 *      - constant product with a 0.3% fee, so k never decreases on a swap;
 *      - the first MINIMUM_LIQUIDITY of LP is locked, killing the first-depositor inflation attack;
 *      - amounts are measured by balance diff (fee-on-transfer safe) and reserves are synced to
 *        the real balances after every op;
 *      - SafeERC20 + ReentrancyGuard + strict CEI on every state-changing function;
 *      - Math.mulDiv keeps the swap/quote math overflow-free and precise.
 *      Rebasing tokens (balance changes out of band) are not supported.
 */
contract MiniSwap is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error IdenticalTokens();
    error ZeroAmount();
    error InvalidToken();
    error NoLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error SlippageExceeded();

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 private constant MINIMUM_LIQUIDITY = 1000; // locked forever on the first deposit
    uint256 private constant FEE_BPS = 30; // 0.3% swap fee
    uint256 private constant BPS = 10_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event Swapped(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address token0_, address token1_) ERC20("MiniSwap LP", "MLP") {
        if (token0_ == address(0) || token1_ == address(0)) revert ZeroAddress();
        if (token0_ == token1_) revert IdenticalTokens();
        token0 = IERC20(token0_);
        token1 = IERC20(token1_);
    }

    /**
     * @notice Add liquidity and receive LP tokens.
     * @dev First deposit sets the price and locks MINIMUM_LIQUIDITY of LP. Later deposits must keep
     *      the current ratio, so only the matching amounts are pulled. Amounts are measured by
     *      balance diff (fee-on-transfer safe).
     * @param amount0Desired Max amount of token0 to deposit.
     * @param amount1Desired Max amount of token1 to deposit.
     * @param minShares Minimum LP tokens to accept (slippage guard).
     * @return shares LP tokens minted to the caller.
     */
    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

        uint256 supply = totalSupply();
        (uint256 amount0, uint256 amount1) = _optimalAmounts(supply, amount0Desired, amount1Desired);

        uint256 received0 = _pull(token0, amount0);
        uint256 received1 = _pull(token1, amount1);

        if (supply == 0) {
            uint256 liquidity = Math.sqrt(received0 * received1);
            if (liquidity <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted(); // first deposit too small
            shares = liquidity - MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY); // lock the first slice of liquidity forever
        } else {
            shares = Math.min(Math.mulDiv(received0, supply, reserve0), Math.mulDiv(received1, supply, reserve1));
        }
        if (shares == 0 || shares < minShares) revert InsufficientLiquidityMinted();

        _mint(msg.sender, shares);
        _sync();
        emit LiquidityAdded(msg.sender, received0, received1, shares);
    }

    /**
     * @notice Burn LP tokens and withdraw the underlying token0/token1 pro-rata.
     * @param shares LP tokens to burn.
     * @param minAmount0 Minimum token0 to accept (slippage guard).
     * @param minAmount1 Minimum token1 to accept (slippage guard).
     * @return amount0 token0 returned to the caller.
     * @return amount1 token1 returned to the caller.
     */
    function removeLiquidity(uint256 shares, uint256 minAmount0, uint256 minAmount1)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroAmount();

        uint256 supply = totalSupply();
        amount0 = Math.mulDiv(shares, reserve0, supply);
        amount1 = Math.mulDiv(shares, reserve1, supply);
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        if (amount0 < minAmount0 || amount1 < minAmount1) revert SlippageExceeded();

        _burn(msg.sender, shares); // reverts if the caller doesn't hold enough LP
        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);
        _sync();
        emit LiquidityRemoved(msg.sender, amount0, amount1, shares);
    }

    /**
     * @notice Swap an exact amount of one token for as much of the other as the curve allows.
     * @dev Applies the 0.3% fee, so the invariant k = reserve0 * reserve1 never decreases.
     * @param tokenIn The token being sold (must be token0 or token1).
     * @param amountIn Amount of `tokenIn` to sell.
     * @param minAmountOut Minimum output to accept (slippage guard).
     * @return amountOut Amount of the other token sent to the caller.
     */
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn != address(token0) && tokenIn != address(token1)) revert InvalidToken();

        bool zeroForOne = tokenIn == address(token0);
        (IERC20 inToken, IERC20 outToken, uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (token0, token1, reserve0, reserve1) : (token1, token0, reserve1, reserve0);
        if (reserveIn == 0 || reserveOut == 0) revert NoLiquidity();

        uint256 received = _pull(inToken, amountIn);
        amountOut = getAmountOut(received, reserveIn, reserveOut);
        if (amountOut == 0 || amountOut < minAmountOut) revert SlippageExceeded();

        outToken.safeTransfer(msg.sender, amountOut);
        _sync();
        emit Swapped(msg.sender, tokenIn, received, amountOut);
    }

    /// @notice Current reserves (token0, token1).
    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    /// @notice Output for a given input along the curve, after the 0.3% fee. Pure helper for quotes.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * (BPS - FEE_BPS);
        // mulDiv avoids overflow on amountInWithFee * reserveOut and keeps full precision.
        return Math.mulDiv(amountInWithFee, reserveOut, reserveIn * BPS + amountInWithFee);
    }

    // --- internal ---

    /// @dev Pull `amount` of `token` from the caller and return what actually arrived.
    function _pull(IERC20 token, uint256 amount) private returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();
    }

    /// @dev Pick the amounts that keep the pool's current ratio (first deposit takes both as-is).
    function _optimalAmounts(uint256 supply, uint256 amount0Desired, uint256 amount1Desired)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (supply == 0) return (amount0Desired, amount1Desired);

        uint256 amount1Optimal = Math.mulDiv(amount0Desired, reserve1, reserve0);
        if (amount1Optimal <= amount1Desired) {
            (amount0, amount1) = (amount0Desired, amount1Optimal);
        } else {
            uint256 amount0Optimal = Math.mulDiv(amount1Desired, reserve0, reserve1);
            (amount0, amount1) = (amount0Optimal, amount1Desired);
        }
    }

    /// @dev Sync stored reserves to the real balances (absorbs any direct token donations too).
    function _sync() private {
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));
    }
}
