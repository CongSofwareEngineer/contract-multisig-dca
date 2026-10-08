# Swap V3
> Last updated: 2026-10-08

## Overview
Operator swaps via Uniswap V3 SwapRouter02 `exactInputSingle`. Output always lands in the vault.
**Only USDC pools run**: one side of every swap must be USDC (cbBTC/USDC, WETH/USDC — i.e. USDC ↔ any whitelisted token). Token ↔ token routes such as WETH ↔ cbBTC are rejected.
Sub-logics:
1. `swapExactInputV3` (buy USDC→token / sell token→USDC)
2. `withdrawAndSwapV3` (Morpho → buy in one tx)
3. `allowedFee`
4. Atomic approvals & output measurement
5. Changing the router (`ChangeUniV3Router`)

## Shared
- Code: `src/vault/DCAVaultSwapV3.sol` (`swapExactInputV3`, `withdrawAndSwapV3`, `_swapV3`); checks `_checkSwap` and post-swap `_settleSwap`, shared with V4, live in the base `src/vault/DCAVaultSwap.sol`; fee setter `_setAllowedFee` in `src/vault/DCAVaultRoles.sol`.
- Storage `uniV3Router` (constructor, then only via a `ChangeUniV3Router` proposal), `allowedFee[uint24]`, `allowedToken`.
- Event `UniV3RouterChanged(oldRouter, newRouter)`; error `SameAddress`.
- Event `Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, version)` — `version = SWAP_VERSION_V3 = 3`.
- Errors: `TokenNotAllowed`, `SameToken`, `PairNotAllowed`, `ZeroAmount`, `DeadlinePassed`, `FeeNotAllowed`, `InsufficientBalance`, `InsufficientOutput`.

## 1. swapExactInputV3
### Entry points
`swapExactInputV3(tokenIn, tokenOut, fee, amountIn, amountOutMinimum, deadline)` — `onlyOperator whenNotPaused nonReentrant`, returns `amountOut`.
### Flow (`_swapV3`)
1. Checks (`_checkSwap`, shared with V4): both tokens whitelisted, `tokenIn != tokenOut`, `tokenIn == usdc || tokenOut == usdc` (else `PairNotAllowed`), `amountIn > 0`, `amountOutMinimum > 0`, `block.timestamp <= deadline`, `allowedFee[fee]`, `amountIn <= balance(tokenIn)`.
2. Snapshot `balance(tokenOut)`.
3. `forceApprove(router, amountIn)` → `exactInputSingle({recipient: address(this), sqrtPriceLimitX96: 0, ...})` → `forceApprove(router, 0)`.
4–6. `_settleSwap` (shared with V4): `amountOut = balance(tokenOut) after − before`; require `>= amountOutMinimum`; emit `Swapped`;
   if `tokenOut == usdc` (sell): `_supplyToMorpho(amountOut)` + emit `MorphoDeposited`. Only the proceeds are supplied; pre-existing idle USDC is untouched.
### Security
- Invariant #2: `recipient` hardcoded. Invariant #3: approve exact → reset 0.
- The router's return value is not trusted; output is measured by balance delta (catches a lying router).
- Slippage is the bot's responsibility (QuoterV2 off-chain); the contract only enforces `amountOutMinimum > 0`. **Accepted risk:** a stolen operator key can sandwich the vault's own swaps (`minOut = 1`) — see [security-safety §5](security-safety.md#5-accepted-risks).
- The USDC-side rule limits the operator to the (deepest) USDC pools of whitelisted tokens, shrinking the set of pools a compromised operator could route value through.
### Edge cases
- SwapRouter02 on Base has **no `deadline`** field; the vault checks it.
- Decimals: USDC 6, WETH 18, cbBTC 8 — amounts are raw token units, nothing assumes 18.

## 2. withdrawAndSwapV3
`withdrawAndSwapV3(tokenOut, fee, usdcAmount, amountOutMinimum, deadline)` — same modifiers.
Flow: reject `usdcAmount == 0`, `tokenOut == usdc`, non-whitelisted `tokenOut` → `withdraw(usdcAmount)` from Morpho → emit `MorphoWithdrawn` → `_swapV3(usdc, tokenOut, ...)`.
If the swap fails, the whole tx reverts and the USDC remains in Morpho.

## 3. allowedFee
Only fee tiers in `allowedFee` can be used (V3 **and** V4 — V4 additionally needs `allowedTickSpacing`, see [swap-v4 §2](swap-v4.md#2-allowedtickspacing-whitelist)). Constructor default (deploy script): `500`, `3000`. Changed via `SetAllowedFee(fee, allowed)` proposal (fee > 0). No per-tx / per-day caps, no TWAP check (by design, spec §7).

Liquidity verified on Base (2026-10-08): USDC/WETH 500 ✓, USDC/cbBTC 500 ✓ (direct buy works). (WETH/cbBTC pools exist but are not usable — USDC-side rule.)
With `FEES=500` only, exactly two pools are reachable: USDC/WETH 500 and USDC/cbBTC 500. With `500,3000`, the 3000 tier of the same two pairs is reachable too.

## 4. Atomic approvals & output measurement
See §1 steps 3–4. After every call, allowance of the vault to the router is 0 for every token.

## 5. Changing the router (`ChangeUniV3Router`)
### Purpose
Lets the signers point swaps at a new SwapRouter02 (e.g. Uniswap redeploys, or a router is found to be compromised) without redeploying the vault.
### Entry points
Proposal `ChangeUniV3Router(address newRouter)` / `proposeChangeUniV3Router` — `onlySigner`, executes only at threshold.
### Flow
`_validate`: `newRouter != 0`, `!= uniV3Router` → at threshold `_changeUniV3Router`: same checks again, `uniV3Router = newRouter`, emit `UniV3RouterChanged(old, new)`. The next `_swapV3` reads the new address.
### Security
- No allowance migration is needed: approvals are always reset to 0 in the swap tx (invariant #3), so the old router has no power over vault funds after the switch (tested: `test_Security_OldRouterHasNoPowerAfterChange`).
- The new router is **not validated on-chain**. Operator swaps hand `tokenIn` to it, so a malicious router could keep it — signers must verify the address (Uniswap docs + basescan) before approving. Same trust level as `AddWithdrawAddress` + `WithdrawBatch`.
- Operators / outsiders cannot propose or vote; one signer below threshold cannot change it (`test_Security_ChangeProtocolAddressesNeedThreshold`).
### Edge cases
- The new router must use the SwapRouter02 `ExactInputSingleParams` (no `deadline` field); a SwapRouter V1-style router would make every swap revert (nothing lost — just pause / change back).

## Related
- [morpho-integration.md](morpho-integration.md)
- [swap-v4.md](swap-v4.md)
- [security-safety.md](security-safety.md)
