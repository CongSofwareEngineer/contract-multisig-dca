// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {DCAVaultSwap} from "./DCAVaultSwap.sol";

/// @title DCAVaultSwapV3
/// @notice Operator swaps through Uniswap V3 SwapRouter02: `swapExactInputV3`, `withdrawAndSwapV3`.
/// @dev Output always goes to address(this); router approval is exact and reset to 0 in the same call.
abstract contract DCAVaultSwapV3 is DCAVaultSwap {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Swaps an exact amount of a whitelisted token held by the vault via Uniswap V3.
    ///         Used for both buys and sells. One side must be `stableToken`. If `tokenOut` is the stable, the
    ///         output is supplied to Morpho. Native ETH (address(0)) is not supported on V3 — use WETH or V4.
    /// @param tokenIn token to sell (`stableToken` for a buy)
    /// @param tokenOut token to buy (`stableToken` for a sell)
    /// @param fee Uniswap V3 fee tier; (token, fee, V3_POOL) must be in `allowedPool`
    /// @param amountIn exact amount of `tokenIn` to sell
    /// @param amountOutMinimum minimum output (> 0); slippage is computed off-chain by the bot
    /// @param deadline unix timestamp after which the swap reverts
    /// @return amountOut amount of `tokenOut` received by the vault
    function swapExactInputV3(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 amountOut) {
        amountOut = _swapV3(tokenIn, tokenOut, fee, amountIn, amountOutMinimum, deadline);
    }

    /// @notice Buy order: withdraws exactly `stableAmount` from Morpho, then swaps stable -> `tokenOut`.
    ///         If the swap fails the whole tx reverts and the stable stays in Morpho.
    /// @param tokenOut whitelisted tradable token to buy (not the stable, not native ETH)
    /// @param fee Uniswap V3 fee tier; (tokenOut, fee, V3_POOL) must be in `allowedPool`
    /// @param stableAmount exact stable amount to withdraw and sell
    /// @param amountOutMinimum minimum output (> 0)
    /// @param deadline unix timestamp after which the swap reverts
    /// @return amountOut amount of `tokenOut` received by the vault
    function withdrawAndSwapV3(
        address tokenOut,
        uint24 fee,
        uint256 stableAmount,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 amountOut) {
        if (stableAmount == 0) revert ZeroAmount();
        address stable = stableToken;
        // Validate cheap swap params before touching Morpho (same checks are repeated in _swapV3).
        if (tokenOut == NATIVE) revert NativeNotSupported();
        if (!allowedToken[tokenOut]) revert TokenNotAllowed(); // also rejects tokenOut == stable
        if (!allowedPool[tokenOut][fee][V3_POOL]) revert PoolNotAllowed();
        uint256 shares = _withdrawFromMorpho(stableAmount);
        emit MorphoWithdrawn(stableAmount, shares);
        amountOut = _swapV3(stable, tokenOut, fee, stableAmount, amountOutMinimum, deadline);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _swapV3(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        // SwapRouter02 only trades ERC20s; native ETH must go through WETH or V4.
        if (tokenIn == NATIVE || tokenOut == NATIVE) revert NativeNotSupported();
        _checkSwap(tokenIn, tokenOut, fee, V3_POOL, amountIn, amountOutMinimum, deadline);
        if (amountIn > IERC20(tokenIn).balanceOf(address(this))) revert InsufficientBalance();

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        // Atomic approval: exact amount -> swap -> reset to 0 (invariant 3).
        address router = uniV3Router;
        IERC20(tokenIn).forceApprove(router, amountIn);
        ISwapRouter02(router)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this), // hardcoded — never a parameter (invariant 2)
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(tokenIn).forceApprove(router, 0);

        amountOut = _settleSwap(tokenIn, tokenOut, fee, amountIn, amountOutMinimum, outBefore, SWAP_VERSION_V3);
    }
}
