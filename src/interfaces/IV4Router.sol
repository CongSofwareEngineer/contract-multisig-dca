// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap V4 types used to build a `V4_SWAP` command for the UniversalRouter.
/// @dev `Currency` and `IHooks` are user-defined `address` types upstream; they ABI-encode exactly like
///      `address`, so plain addresses are used here to avoid pulling in v4-core / v4-periphery.
interface IV4Router {
    /// @notice v4-core `PoolKey`. `currency0 < currency1` (sorted by address).
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @notice v4-periphery `IV4Router.ExactInputSingleParams` (param of `SWAP_EXACT_IN_SINGLE`).
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }
}
