# Swap V3
> Last updated: 2026-10-08

## Overview
Operator swaps via Uniswap V3 SwapRouter02 `exactInputSingle`. Output always lands in the vault.
Sub-logics:
1. `swapExactInputV3` (buy / sell / token↔token)
2. `withdrawAndSwapV3` (Morpho → buy in one tx)
3. `allowedFee`
4. Atomic approvals & output measurement

## Shared
- Immutable `uniV3Router`. Storage `allowedFee[uint24]`, `allowedToken`.
- Event `Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, version)` — `version = SWAP_VERSION_V3 = 3`.
- Errors: `TokenNotAllowed`, `SameToken`, `ZeroAmount`, `DeadlinePassed`, `FeeNotAllowed`, `InsufficientBalance`, `InsufficientOutput`.

## 1. swapExactInputV3
### Entry points
`swapExactInputV3(tokenIn, tokenOut, fee, amountIn, amountOutMinimum, deadline)` — `onlyOperator whenNotPaused nonReentrant`, returns `amountOut`.
### Flow (`_swapV3`)
1. Checks: both tokens whitelisted, `tokenIn != tokenOut`, `amountIn > 0`, `amountOutMinimum > 0`, `block.timestamp <= deadline`, `allowedFee[fee]`, `amountIn <= balance(tokenIn)`.
2. Snapshot `balance(tokenOut)`.
3. `forceApprove(router, amountIn)` → `exactInputSingle({recipient: address(this), sqrtPriceLimitX96: 0, ...})` → `forceApprove(router, 0)`.
4. `amountOut = balance(tokenOut) after − before`; require `>= amountOutMinimum`.
5. Emit `Swapped`.
6. If `tokenOut == usdc` (sell): `_supplyToMorpho(amountOut)` + emit `MorphoDeposited`. Only the proceeds are supplied; pre-existing idle USDC is untouched.
### Security
- Invariant #2: `recipient` hardcoded. Invariant #3: approve exact → reset 0.
- The router's return value is not trusted; output is measured by balance delta (catches a lying router).
- Slippage is the bot's responsibility (QuoterV2 off-chain); the contract only enforces `amountOutMinimum > 0`.
### Edge cases
- SwapRouter02 on Base has **no `deadline`** field; the vault checks it.
- Decimals: USDC 6, WETH 18, cbBTC 8 — amounts are raw token units, nothing assumes 18.

## 2. withdrawAndSwapV3
`withdrawAndSwapV3(tokenOut, fee, usdcAmount, amountOutMinimum, deadline)` — same modifiers.
Flow: reject `usdcAmount == 0`, `tokenOut == usdc`, non-whitelisted `tokenOut` → `withdraw(usdcAmount)` from Morpho → emit `MorphoWithdrawn` → `_swapV3(usdc, tokenOut, ...)`.
If the swap fails, the whole tx reverts and the USDC remains in Morpho.

## 3. allowedFee
Only fee tiers in `allowedFee` can be used. Constructor default (deploy script): `500`, `3000`. Changed via `SetAllowedFee(fee, allowed)` proposal (fee > 0). No per-tx / per-day caps, no TWAP check (by design, spec §7).

Liquidity verified on Base (2026-10-08): USDC/WETH 500 ✓, WETH/cbBTC 3000 ✓ (500 also deep), USDC/cbBTC 500 ✓ (direct buy works).

## 4. Atomic approvals & output measurement
See §1 steps 3–4. After every call, allowance of the vault to the router is 0 for every token.

## Related
- [morpho-integration.md](morpho-integration.md)
- [swap-v4.md](swap-v4.md)
- [security-safety.md](security-safety.md)
