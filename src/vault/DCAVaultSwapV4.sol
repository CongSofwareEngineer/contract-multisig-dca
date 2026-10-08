// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "../interfaces/IPermit2.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {IV4Router} from "../interfaces/IV4Router.sol";
import {DCAVaultSwap} from "./DCAVaultSwap.sol";

/// @title DCAVaultSwapV4
/// @notice Operator swaps through Uniswap V4 pools via UniversalRouter + Permit2: `swapExactInputV4`.
/// @dev Commands are built by the vault (never operator calldata), `hooks = address(0)`, output always goes to
///      address(this); ERC20 -> Permit2 and Permit2 -> UniversalRouter approvals are exact and reset to 0.
///      Native ETH (`NATIVE` = address(0), once whitelisted): sold by sending exactly `amountIn` as msg.value
///      (no approvals), bought via `receive()`, which only accepts ETH while such a swap is in progress.
abstract contract DCAVaultSwapV4 is DCAVaultSwap {
    using SafeERC20 for IERC20;

    // UniversalRouter command / v4-periphery action ids (Commands.sol, Actions.sol).
    bytes1 private constant V4_SWAP = 0x10;
    bytes1 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 private constant SETTLE_ALL = 0x0c;
    bytes1 private constant TAKE_ALL = 0x0f;

    // ------------------------------------------------------------------
    // Receive
    // ------------------------------------------------------------------

    /// @notice Accepts native ETH only as the output of an in-progress `swapExactInputV4` buying ETH
    ///         (sent by the V4 PoolManager on TAKE_ALL). Any other ETH transfer reverts.
    /// @dev Not `nonReentrant`: it runs inside the swap that already holds the lock; it only reads a flag.
    receive() external payable {
        if (!_expectingNative) revert UnexpectedNative();
    }

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Swaps an exact amount of a whitelisted token via a Uniswap V4 pool (UniversalRouter + Permit2).
    ///         Same rules as `swapExactInputV3`: one side must be `stableToken`; a sell to the stable is supplied
    ///         to Morpho. Unlike V3, native ETH (address(0)) works here if it is whitelisted.
    /// @dev The vault builds `commands` / `inputs` itself (V4_SWAP: SWAP_EXACT_IN_SINGLE + SETTLE_ALL + TAKE_ALL);
    ///      the operator never supplies calldata. `PoolKey.hooks` is hardcoded to `address(0)`.
    ///      TAKE_ALL pays the UniversalRouter's caller, i.e. always this vault.
    /// @param tokenIn token to sell (`stableToken` for a buy; address(0) = native ETH)
    /// @param tokenOut token to buy (`stableToken` for a sell; address(0) = native ETH)
    /// @param fee pool fee
    /// @param tickSpacing V4 tick spacing (>= 1); (token, fee, tickSpacing) must be in `allowedPool`
    /// @param amountIn exact amount of `tokenIn` to sell (<= uint128 max)
    /// @param amountOutMinimum minimum output (> 0, <= uint128 max); computed off-chain by the bot
    /// @param deadline unix timestamp after which the swap reverts
    /// @return amountOut amount of `tokenOut` received by the vault
    function swapExactInputV4(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 amountOut) {
        // tickSpacing 0 is the V3 marker in `allowedPool` — never let it unlock a V4 swap.
        if (tickSpacing < MIN_TICK_SPACING) revert PoolNotAllowed();
        _checkSwap(tokenIn, tokenOut, fee, tickSpacing, amountIn, amountOutMinimum, deadline);
        // V4 router params are uint128; reject instead of silently truncating.
        if (amountIn > type(uint128).max || amountOutMinimum > type(uint128).max) revert AmountTooLarge();

        uint256 inBefore = _balanceOf(tokenIn);
        if (amountIn > inBefore) revert InsufficientBalance();
        uint256 outBefore = _balanceOf(tokenOut);

        bytes memory swapInput = _buildV4SwapInput(tokenIn, tokenOut, fee, tickSpacing, amountIn, amountOutMinimum);
        if (tokenOut == NATIVE) _expectingNative = true; // open receive() for this swap only
        _executeV4(tokenIn, amountIn, deadline, swapInput);
        _expectingNative = false;

        // Don't trust the router: tokenIn spent <= amountIn, tokenOut received >= amountOutMinimum.
        if (inBefore - _balanceOf(tokenIn) > amountIn) revert ExcessiveInput();
        amountOut = _settleSwap(tokenIn, tokenOut, fee, amountIn, amountOutMinimum, outBefore, SWAP_VERSION_V4);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Atomic approvals (invariant 3): ERC20 -> Permit2 and Permit2 -> UniversalRouter, both exact,
    ///      the Permit2 one expiring this block; both reset to 0 right after the swap.
    ///      Native ETH in: no approval at all — exactly `amountIn` is sent as msg.value and SETTLE_ALL pays the
    ///      PoolManager from it.
    function _executeV4(address tokenIn, uint256 amountIn, uint256 deadline, bytes memory swapInput) internal {
        address router = universalRouter;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = swapInput;

        if (tokenIn == NATIVE) {
            IUniversalRouter(router).execute{value: amountIn}(abi.encodePacked(V4_SWAP), inputs, deadline);
            return;
        }

        address p2 = permit2;
        IERC20(tokenIn).forceApprove(p2, amountIn);
        IPermit2(p2).approve(tokenIn, router, uint160(amountIn), uint48(block.timestamp));
        IUniversalRouter(router).execute(abi.encodePacked(V4_SWAP), inputs, deadline);
        IPermit2(p2).approve(tokenIn, router, 0, 0);
        IERC20(tokenIn).forceApprove(p2, 0);
    }

    /// @dev Builds the `V4_SWAP` input for one exact-input single-pool swap. Every field comes from
    ///      validated parameters or constants — no operator-supplied bytes reach the router.
    function _buildV4SwapInput(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal pure returns (bytes memory) {
        // address(0) (native ETH) always sorts first, i.e. it is currency0 — as in V4 native pools.
        bool zeroForOne = tokenIn < tokenOut;
        IV4Router.PoolKey memory key = IV4Router.PoolKey({
            currency0: zeroForOne ? tokenIn : tokenOut,
            currency1: zeroForOne ? tokenOut : tokenIn,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: address(0) // no hooked pools: a hook could run arbitrary code around our swap
        });

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(amountOutMinimum),
                hookData: ""
            })
        );
        params[1] = abi.encode(tokenIn, amountIn); // SETTLE_ALL(currency, maxAmount): Permit2, or msg.value if native
        params[2] = abi.encode(tokenOut, amountOutMinimum); // TAKE_ALL(currency, minAmount): to msg.sender

        return abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
    }
}
