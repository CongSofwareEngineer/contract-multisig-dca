// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap V3 SwapRouter02 interface (Base: 0x2626664c2603336E57B271c5C0b26F421741e481).
/// @dev SwapRouter02 has NO `deadline` field in ExactInputSingleParams (unlike SwapRouter V1),
///      so DCAVault checks the deadline itself.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
