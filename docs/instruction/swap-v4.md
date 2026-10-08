# Swap V4
> Last updated: 2026-10-08

## Overview
Operator swaps through **Uniswap V4** pools, via the UniversalRouter + Permit2. Same rules as V3 (one side must be `stableToken`, output stays in the vault, a buy pulls exactly `amountIn` stable from Morpho in the same tx, a sell to the stable is supplied to Morpho), and the same pool whitelist: `(token, fee, tickSpacing)` must be one entry of `allowedPool` ([swap-v3 §3](swap-v3.md#3-pool-whitelist-allowedpool--shared-with-v4)), with `hooks` always `address(0)`. Unlike V3, V4 can trade **native ETH** (`address(0)`) once it is whitelisted in `allowedToken`.
Sub-logics:
1. `swapExactInputV4`
2. Changing Permit2 / UniversalRouter

## Shared
- Code: `swapExactInputV4`, `_executeV4`, `_buildV4SwapInput` in `src/vault/DCAVaultSwapV4.sol`; shared `_prepareSwap` / `_settleSwap` (same as V3) in the base `src/vault/DCAVaultSwap.sol`; storage, constants, events, errors in `src/vault/DCAVaultStorage.sol`; pool whitelist (`_setAllowedPool`) in `src/vault/DCAVaultRoles.sol`; proposal handlers in `src/vault/DCAVaultProposals.sol`.
- Storage: `permit2`, `universalRouter` (constructor, non-zero; then only via proposal); pool whitelist `allowedPool` (shared with V3).
- Constants: `SWAP_VERSION_V4 = 4`, `MIN_TICK_SPACING = 1`, `MAX_TICK_SPACING = 32767` (v4-core bounds). Private: `V4_SWAP = 0x10`, `SWAP_EXACT_IN_SINGLE = 0x06`, `SETTLE_ALL = 0x0c`, `TAKE_ALL = 0x0f`.
- Events: `Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, 4)`, `Permit2Changed`, `UniversalRouterChanged`.
- Errors: `PoolNotAllowed`, `AmountTooLarge`, `ExcessiveInput`, `UnexpectedNative`, plus the shared swap errors.
- `receive()` lives here: it accepts ETH only while `_expectingNative` is set (native-ETH buy in progress).
- Interfaces: `src/interfaces/IPermit2.sol`, `src/interfaces/IUniversalRouter.sol`, `src/interfaces/IV4Router.sol` (`PoolKey`, `ExactInputSingleParams`; `Currency` / `IHooks` written as `address`, same ABI encoding).

## 1. swapExactInputV4
### Purpose
Exact-input swap through one hookless V4 pool. Used for buys (stable → WETH / cbBTC / native ETH) and sells (→ stable).
### Entry points
`swapExactInputV4(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)` — `onlyOperator whenNotPaused nonReentrant`, returns `amountOut`.
### Flow
1. `tickSpacing >= 1` (else `PoolNotAllowed`: 0 is the V3 marker in `allowedPool` and must never unlock a V4 swap); `amountIn` and `amountOutMinimum` ≤ `uint128.max` (`AmountTooLarge`; V4 params are uint128 — never truncated).
2. `_prepareSwap` (same as V3): one side is `stableToken`, the other in `allowedToken`, `amountIn > 0`, `amountOutMinimum > 0`, `block.timestamp <= deadline`, `allowedPool[token][fee][tickSpacing]` (`PoolNotAllowed`). **Buy** (`tokenIn == stableToken`): only after every check, withdraw exactly `amountIn` from Morpho (receiver / owner = vault) and emit `MorphoWithdrawn` — one tx (there is no public `morphoWithdraw`).
3. Snapshot balances (`_balanceOf`: native ETH → `address(this).balance`); `amountIn <= balance(tokenIn)`.
4. Build the input (`_buildV4SwapInput`): `PoolKey{currency0, currency1 = sorted(tokenIn, tokenOut), fee, tickSpacing, hooks: address(0)}`, `zeroForOne = tokenIn < tokenOut`; actions `SWAP_EXACT_IN_SINGLE` + `SETTLE_ALL(tokenIn, amountIn)` + `TAKE_ALL(tokenOut, amountOutMinimum)`; `hookData = ""`.
5. If `tokenOut == address(0)`: set `_expectingNative = true` (opens `receive()`).
   `_executeV4`:
   - ERC20 in: `forceApprove(tokenIn → permit2, amountIn)` → `IPermit2.approve(tokenIn, universalRouter, uint160(amountIn), uint48(block.timestamp))` → `UniversalRouter.execute(0x10, [input], deadline)` → `IPermit2.approve(tokenIn, universalRouter, 0, 0)` → `forceApprove(tokenIn → permit2, 0)`.
   - Native ETH in: **no approvals**. `UniversalRouter.execute{value: amountIn}(0x10, [input], deadline)`; `SETTLE_ALL` pays the PoolManager from that ETH.
   Then `_expectingNative = false`. For a native-ETH buy, the PoolManager sends the ETH to the vault during `TAKE_ALL`, and `receive()` accepts it only inside this window.
6. Verify: tokenIn spent ≤ `amountIn` (`ExcessiveInput`); tokenOut received ≥ `amountOutMinimum` (`InsufficientOutput`), measured by balance delta.
7. Emit `Swapped(..., 4)`. If `tokenOut == stableToken`, the received stable is supplied to Morpho (`MorphoDeposited`); idle stable already in the vault is not touched. Bought tokens / ETH stay idle in the vault.

The bot buys with V4 in **one tx**: `swapExactInputV4(stableToken, tokenOut, fee, tickSpacing, x, minOut, deadline)` withdraws exactly `x` from Morpho and swaps it. Idle stable already in the vault is not used for a buy (put it back with `morphoDeposit`); Morpho short of `x` → reverts with Morpho's error. If the swap fails the whole tx reverts and the stable stays in Morpho.
### Security
- **No operator calldata** (invariant 9): commands / actions are constants, every param comes from validated arguments.
- **Output to the vault** (invariant 2): `TAKE_ALL` pays the UniversalRouter's `msg.sender`, i.e. always the vault. No recipient parameter exists.
- **No standing approvals** (invariant 3): both the ERC20 → Permit2 and the Permit2 → UniversalRouter allowance are exact, reset to 0 in the same call; the Permit2 one also expires this block.
- **No hooked pools**: `hooks = address(0)` is hardcoded — a hook could run arbitrary code around the swap.
- **Native ETH window** (invariant 10): `receive()` only accepts ETH while a native-ETH buy is in progress. A router pushing ETH during any other swap makes the whole swap revert.
- Pool choice is pinned to the listed `(token, fee, tickSpacing)` entries — the operator cannot mix a fee and a spacing into an unlisted (possibly attacker-created) pool. Slippage is the bot's job (`amountOutMinimum`), same accepted risk as V3 (security-safety §accepted risks).
### Edge cases
- A listed pool that is not initialized / has no liquidity → router reverts, whole tx reverts. Only list pools that exist with liquidity (anyone can initialize a missing one).
- `deadline` checked by the vault and again by the UniversalRouter.
- Native-ETH V4 pools are reachable only after `AddToken(address(0))` **and** a pool entry such as `(address(0), 500, 10)`. `address(0)` always sorts first, so it is `currency0`, exactly as in V4 native pools. Fork-tested on Base (2026-10-08): ETH/USDC `500/10` hookless, buy + sell.
- Paused → `IsPaused`.
- Hookless pools with liquidity on Base (checked 2026-10-08): WETH/USDC `500/10`, `3000/60`; USDC/cbBTC `500/10` (thin: `100/1`, `3000/60`, `10000/200`).

## 2. Changing Permit2 / UniversalRouter
Proposals `ChangePermit2(address)` / `ChangeUniversalRouter(address)` (`proposeChangePermit2`, `proposeChangeUniversalRouter`) — `onlySigner`, threshold. Checks `!= 0` and `!= current` (`SameAddress`) at propose and execute, then set the address and emit the event. Not validated on-chain — signers verify before approving. No allowance migration needed: approvals are reset to 0 in every swap. `swapExactInputV4` reads both addresses from storage at call time.

## Related
- [swap-v3.md](swap-v3.md) — shared checks, pool whitelist (§3)
- [proposal-system.md](proposal-system.md) — proposal table
- [security-safety.md](security-safety.md) — §10 invariants, pause
- [deployment.md](deployment.md) — constructor / env
