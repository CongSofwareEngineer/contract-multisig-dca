// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {DCAVaultSwap} from "./DCAVaultSwap.sol";

/// @title DCAVaultSwapV3
/// @notice Operator swaps (buy and sell) through Uniswap V3 SwapRouter02: `swapExactInputV3`.
/// @dev Output always goes to address(this); router approval is exact and reset to 0 in the same call.
abstract contract DCAVaultSwapV3 is DCAVaultSwap {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Swaps an exact amount via Uniswap V3 SwapRouter02. One side must be `stableToken`.
    ///         Buy (`tokenIn == stableToken`): withdraws exactly `amountIn` from Morpho, then swaps, in one tx
    ///         (idle stable in the vault is not used). Sell: swaps a token the vault holds and supplies the stable
    ///         received to Morpho. Native ETH (address(0)) is not supported on V3 — use WETH or V4.
    /// @param tokenIn token to sell (`stableToken` for a buy)
    /// @param tokenOut token to buy (`stableToken` for a sell)
    /// @param fee Uniswap V3 fee tier; (token, fee, V3_POOL) must be in `allowedPool`
    /// @param amountIn exact amount of `tokenIn` to sell; for a buy, the stable pulled from Morpho
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
        // SwapRouter02 only trades ERC20s; native ETH must go through WETH or V4.
        if (tokenIn == NATIVE || tokenOut == NATIVE) revert NativeNotSupported();
        _prepareSwap(tokenIn, tokenOut, fee, V3_POOL, amountIn, amountOutMinimum, deadline); // buy: pulls from Morpho
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
