# Swap V4 (Phase 2)
> Last updated: 2026-10-08

## Overview
**Not implemented in Phase 1.** The contract already stores immutable `permit2` and `universalRouter` and exposes a stub so the ABI shape is fixed.

## Shared
- Code: stub `swapExactInputV4` in `src/vault/DCAVaultSwap.sol`; immutables in `src/vault/DCAVaultStorage.sol`.
- Immutables `permit2`, `universalRouter` (constructor, must be non-zero).
- Interfaces `src/interfaces/IPermit2.sol`, `src/interfaces/IUniversalRouter.sol`.

## 1. swapExactInputV4 (stub)
### Entry points
`swapExactInputV4(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)` — `onlyOperator whenNotPaused`, **always reverts `NotImplemented()`**.
### Requirements for Phase 2 (from spec §5.2)
- `forceApprove(tokenIn → Permit2, amountIn)` → `IPermit2.approve(token, universalRouter, uint160(amountIn), uint48(block.timestamp))`.
- Contract builds `commands` / `inputs` itself (`V4_SWAP`: `SWAP_EXACT_IN_SINGLE` + `SETTLE_ALL` + `TAKE_ALL`). **Never** accept raw calldata from the operator.
- `PoolKey.hooks` must be `address(0)`.
- Balance check before/after: tokenOut +≥ minOut, tokenIn −≤ amountIn.
- Reset both ERC20 and Permit2 allowances to 0.
- Re-verify the UniversalRouter address on docs.uniswap.org before building.

## Related
- [swap-v3.md](swap-v3.md)
