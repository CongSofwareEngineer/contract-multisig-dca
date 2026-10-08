// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DCAVaultMorpho} from "./DCAVaultMorpho.sol";

/// @title DCAVaultSwap
/// @notice Shared base of the swap modules: the checks every swap must pass and the post-swap settlement.
/// @dev `DCAVaultSwapV3` and `DCAVaultSwapV4` both build on this, so V3 and V4 can never drift apart on the
///      rules (stable side, token whitelist, pool whitelist, deadline, balance-delta output check, sell -> Morpho).
abstract contract DCAVaultSwap is DCAVaultMorpho {
    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Checks shared by V3 and V4 swaps. `tickSpacing` is `V3_POOL` for V3, the V4 pool's spacing for V4.
    function _checkSwap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) internal view {
        // Exactly one side is the stable, the other a whitelisted tradable token (e.g. WETH/USDC, ETH/USDC).
        // No token <-> token route. The two lists are disjoint, so this also rules out tokenIn == tokenOut.
        address stable = stableToken;
        address other;
        if (tokenIn == stable) other = tokenOut;
        else if (tokenOut == stable) other = tokenIn;
        else revert PairNotAllowed();
        if (!allowedToken[other]) revert TokenNotAllowed();
        if (amountIn == 0 || amountOutMinimum == 0) revert ZeroAmount();
        // SwapRouter02 on Base has no deadline field, so enforce it here (V4 also passes it to the router).
        if (block.timestamp > deadline) revert DeadlinePassed();
        // The exact pool (stable, other, fee, tickSpacing) must be whitelisted as one entry: the operator cannot
        // pick an unused fee / spacing combo where it could seed its own pool at a rigged price.
        if (!allowedPool[other][fee][tickSpacing]) revert PoolNotAllowed();
    }

    /// @dev Measures what actually arrived (never trusts the router's return value), emits `Swapped`,
    ///      and supplies sell proceeds to Morpho so they never sit idle.
    function _settleSwap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 outBefore,
        uint8 version
    ) internal returns (uint256 amountOut) {
        amountOut = _balanceOf(tokenOut) - outBefore;
        if (amountOut < amountOutMinimum) revert InsufficientOutput();
        emit Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, version);

        if (tokenOut == stableToken) {
            uint256 shares = _supplyToMorpho(amountOut);
            emit MorphoDeposited(amountOut, shares);
        }
    }
}
