# Swap V4
> Last updated: 2026-10-08

## Overview
Operator swaps through **Uniswap V4** pools, via the UniversalRouter + Permit2. Same rules as V3 (one side must be USDC, output stays in the vault, a sell to USDC is supplied to Morpho), plus a pool-shape whitelist: `allowedFee` (shared with V3) **and** `allowedTickSpacing`, with `hooks` always `address(0)`.
Sub-logics:
1. `swapExactInputV4`
2. `allowedTickSpacing` whitelist
3. Changing Permit2 / UniversalRouter

## Shared
- Code: `swapExactInputV4`, `_executeV4`, `_buildV4SwapInput` in `src/vault/DCAVaultSwapV4.sol`; shared `_checkSwap` / `_settleSwap` (same as V3) in the base `src/vault/DCAVaultSwap.sol`; storage, constants, events, errors in `src/vault/DCAVaultStorage.sol`; `_setAllowedTickSpacing` in `src/vault/DCAVaultRoles.sol`; proposal handlers in `src/vault/DCAVaultProposals.sol`.
- Storage: `permit2`, `universalRouter` (constructor, non-zero; then only via proposal), `allowedTickSpacing[int24]`.
- Constants: `SWAP_VERSION_V4 = 4`, `MIN_TICK_SPACING = 1`, `MAX_TICK_SPACING = 32767` (v4-core bounds). Private: `V4_SWAP = 0x10`, `SWAP_EXACT_IN_SINGLE = 0x06`, `SETTLE_ALL = 0x0c`, `TAKE_ALL = 0x0f`.
- Events: `Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, 4)`, `TickSpacingAllowed(tickSpacing, allowed)`, `Permit2Changed`, `UniversalRouterChanged`.
- Errors: `TickSpacingNotAllowed`, `InvalidTickSpacing`, `AmountTooLarge`, `ExcessiveInput`, plus the V3 swap errors.
- Interfaces: `src/interfaces/IPermit2.sol`, `src/interfaces/IUniversalRouter.sol`, `src/interfaces/IV4Router.sol` (`PoolKey`, `ExactInputSingleParams`; `Currency` / `IHooks` written as `address`, same ABI encoding).

## 1. swapExactInputV4
### Purpose
Exact-input swap through one hookless V4 pool. Used for buys (USDC → WETH/cbBTC) and sells (→ USDC).
### Entry points
`swapExactInputV4(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)` — `onlyOperator whenNotPaused nonReentrant`, returns `amountOut`.
### Flow
1. Same checks as V3 (`_checkSwap`): both tokens whitelisted, different, one is USDC, `amountIn > 0`, `amountOutMinimum > 0`, `block.timestamp <= deadline`, `allowedFee[fee]`.
2. `allowedTickSpacing[tickSpacing]`; `amountIn` and `amountOutMinimum` ≤ `uint128.max` (V4 params are uint128 — never truncated).
3. Snapshot balances; `amountIn <= balance(tokenIn)`.
4. Build the input (`_buildV4SwapInput`): `PoolKey{currency0, currency1 = sorted(tokenIn, tokenOut), fee, tickSpacing, hooks: address(0)}`, `zeroForOne = tokenIn < tokenOut`; actions `SWAP_EXACT_IN_SINGLE` + `SETTLE_ALL(tokenIn, amountIn)` + `TAKE_ALL(tokenOut, amountOutMinimum)`; `hookData = ""`.
5. `_executeV4`: `forceApprove(tokenIn → permit2, amountIn)` → `IPermit2.approve(tokenIn, universalRouter, uint160(amountIn), uint48(block.timestamp))` → `UniversalRouter.execute(0x10, [input], deadline)` → `IPermit2.approve(tokenIn, universalRouter, 0, 0)` → `forceApprove(tokenIn → permit2, 0)`.
6. Verify: tokenIn spent ≤ `amountIn` (`ExcessiveInput`); tokenOut received ≥ `amountOutMinimum` (`InsufficientOutput`), measured by balance delta.
7. Emit `Swapped(..., 4)`. If `tokenOut == usdc`, the received USDC is supplied to Morpho (`MorphoDeposited`); idle USDC already in the vault is not touched.

The bot buys with V4 in two txs: `morphoWithdraw(x)` then `swapExactInputV4(usdc, …, x, …)` (there is no `withdrawAndSwapV4`, it is not in the spec).
### Security
- **No operator calldata** (invariant 9): commands / actions are constants, every param comes from validated arguments.
- **Output to the vault** (invariant 2): `TAKE_ALL` pays the UniversalRouter's `msg.sender`, i.e. always the vault. No recipient parameter exists.
- **No standing approvals** (invariant 3): both the ERC20 → Permit2 and the Permit2 → UniversalRouter allowance are exact, reset to 0 in the same call; the Permit2 one also expires this block.
- **No hooked pools**: `hooks = address(0)` is hardcoded — a hook could run arbitrary code around the swap.
- Pool choice is bounded by `allowedFee` × `allowedTickSpacing` × USDC pair. Slippage is the bot's job (`amountOutMinimum`), same accepted risk as V3 (security-safety §accepted risks).
### Edge cases
- Pool with that (fee, tickSpacing) not initialized / no liquidity → router reverts, whole tx reverts.
- `deadline` checked by the vault and again by the UniversalRouter.
- Native-ETH V4 pools (`currency0 = address(0)`) are **not** reachable: `address(0)` can never be in `allowedToken`. Only WETH pools.
- Paused → `IsPaused`.
- Hookless pools with liquidity on Base (checked 2026-10-08): WETH/USDC `500/10`, `3000/60`; USDC/cbBTC `500/10` (thin: `100/1`, `3000/60`, `10000/200`).

## 2. allowedTickSpacing whitelist
### Purpose
In V4 a pool is identified by `(currency0, currency1, fee, tickSpacing, hooks)`, and tick spacing is chosen freely per pool (not fixed by fee as in V3). The whitelist limits which tick spacings the operator may route through.
### Entry points
- Constructor `_tickSpacings[]` (deploy script: env `TICK_SPACINGS`, e.g. `10,60`). Duplicate → `Duplicate`; out of range → `InvalidTickSpacing`.
- Proposal `SetAllowedTickSpacing(int24 tickSpacing, bool allowed)` / helper `proposeSetAllowedTickSpacing(tickSpacing, allowed)` — `onlySigner`, threshold. Checked at propose and execute.
### Flow
`_setAllowedTickSpacing`: require `1 <= tickSpacing <= 32767` → set `allowedTickSpacing[tickSpacing] = allowed` → emit `TickSpacingAllowed`.
### Security
Global list, independent of `allowedFee` (any allowed fee × any allowed tick spacing). Only signers can change it; the operator cannot.
### Edge cases
Setting an already-set value is allowed (just re-emits), same as `SetAllowedFee`. Disallowing only blocks future V4 swaps.

## 3. Changing Permit2 / UniversalRouter
Proposals `ChangePermit2(address)` / `ChangeUniversalRouter(address)` (`proposeChangePermit2`, `proposeChangeUniversalRouter`) — `onlySigner`, threshold. Checks `!= 0` and `!= current` (`SameAddress`) at propose and execute, then set the address and emit the event. Not validated on-chain — signers verify before approving. No allowance migration needed: approvals are reset to 0 in every swap. `swapExactInputV4` reads both addresses from storage at call time.

## Related
- [swap-v3.md](swap-v3.md) — shared checks, `allowedFee`
- [proposal-system.md](proposal-system.md) — proposal table
- [security-safety.md](security-safety.md) — §10 invariants, pause
- [deployment.md](deployment.md) — constructor / env
