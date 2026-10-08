// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {DCAVaultMorpho} from "./DCAVaultMorpho.sol";

/// @title DCAVaultSwap
/// @notice Operator swaps: Uniswap V3 (`swapExactInputV3`, `withdrawAndSwapV3`) and the Phase 2 V4 stub.
/// @dev Output always goes to address(this); router approval is exact and reset to 0 in the same call.
abstract contract DCAVaultSwap is DCAVaultMorpho {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Swaps an exact amount of a whitelisted token held by the vault via Uniswap V3.
    ///         Used for both buys and sells. If `tokenOut` is USDC, the output is supplied to Morpho.
    /// @param tokenIn whitelisted token to sell
    /// @param tokenOut whitelisted token to buy
    /// @param fee whitelisted Uniswap V3 fee tier
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

    /// @notice Buy order: withdraws exactly `usdcAmount` from Morpho, then swaps USDC -> `tokenOut`.
    ///         If the swap fails the whole tx reverts and the USDC stays in Morpho.
    /// @param tokenOut whitelisted token to buy (not USDC)
    /// @param fee whitelisted Uniswap V3 fee tier
    /// @param usdcAmount exact USDC amount to withdraw and sell
    /// @param amountOutMinimum minimum output (> 0)
    /// @param deadline unix timestamp after which the swap reverts
    /// @return amountOut amount of `tokenOut` received by the vault
    function withdrawAndSwapV3(
        address tokenOut,
        uint24 fee,
        uint256 usdcAmount,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 amountOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        // Validate cheap swap params before touching Morpho (same checks are repeated in _swapV3).
        if (tokenOut == usdc) revert SameToken();
        if (!allowedToken[tokenOut]) revert TokenNotAllowed();
        uint256 shares = _withdrawFromMorpho(usdcAmount);
        emit MorphoWithdrawn(usdcAmount, shares);
        amountOut = _swapV3(usdc, tokenOut, fee, usdcAmount, amountOutMinimum, deadline);
    }

    /// @notice Phase 2: Uniswap V4 swap via UniversalRouter + Permit2. Not implemented in Phase 1.
    /// @dev Always reverts. Parameter list mirrors the spec so the ABI shape is fixed; the real
    ///      implementation must build commands itself and require `hooks == address(0)`.
    function swapExactInputV4(address, address, uint24, int24, uint256, uint256, uint256)
        external
        view
        onlyOperator
        whenNotPaused
        returns (uint256)
    {
        revert NotImplemented();
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
        if (!allowedToken[tokenIn] || !allowedToken[tokenOut]) revert TokenNotAllowed();
        if (tokenIn == tokenOut) revert SameToken();
        if (amountIn == 0 || amountOutMinimum == 0) revert ZeroAmount();
        // SwapRouter02 on Base has no deadline field, so enforce it here.
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (!allowedFee[fee]) revert FeeNotAllowed();
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

        // Measure what actually arrived instead of trusting the router's return value.
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < amountOutMinimum) revert InsufficientOutput();
        emit Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, SWAP_VERSION_V3);

        // Sell order: proceeds never sit idle.
        if (tokenOut == usdc) {
            uint256 shares = _supplyToMorpho(amountOut);
            emit MorphoDeposited(amountOut, shares);
        }
    }
}
