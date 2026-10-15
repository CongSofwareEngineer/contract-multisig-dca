# Swap V3
> Last updated: 2026-10-15

## Overview
Operator swaps via Uniswap V3 SwapRouter02 `exactInputSingle`. Output always lands in the vault.
**Only stable pools run**: one side of every swap must be `stableToken` (USDC), the other a whitelisted tradable token (cbBTC/USDC, WETH/USDC). Token ↔ token routes such as WETH ↔ cbBTC are rejected. Native ETH (`address(0)`) cannot be traded on V3 (SwapRouter02 only handles ERC20s); use WETH here or native ETH on [V4](swap-v4.md).
Sub-logics:
1. `swapExactInputV3` (buy stable→token, pulling the stable from Morpho in the same tx / sell token→stable)
2. *(removed: `withdrawAndSwapV3` — merged into §1)*
3. Pool whitelist (`allowedPool`) — shared with V4
4. Atomic approvals & output measurement
5. Changing the router (`ChangeUniV3Router`)
6. Daily volume cap (`dailyVolumeCap`) — shared with V4

## Shared
- Code: `src/vault/DCAVaultSwapV3.sol` (`swapExactInputV3`); `_prepareSwap` (checks + Morpho pull on a buy) and post-swap `_settleSwap`, shared with V4, live in the base `src/vault/DCAVaultSwap.sol`; pool whitelist setter `_setAllowedPool` / `_checkPoolConfig` in `src/vault/DCAVaultRoles.sol`.
- Storage `uniV3Router` (constructor, then only via a `ChangeUniV3Router` proposal), `_allowedPool[_poolId(token, fee, tickSpacing)]` (+ `stableEpoch`, `_tokenEpoch`), `stableToken`, `allowedToken`.
- Event `UniV3RouterChanged(oldRouter, newRouter)`; error `SameAddress`.
- Event `Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, version)` — `version = SWAP_VERSION_V3 = 3`; `MorphoWithdrawn(assets, shares)` on a buy, `MorphoDeposited` on a sell.
- Errors: `TokenNotAllowed`, `PairNotAllowed`, `NativeNotSupported`, `ZeroAmount`, `DeadlinePassed`, `PoolNotAllowed`, `InsufficientBalance`, `InsufficientOutput`, `DailyVolumeExceeded` (§6).

## 1. swapExactInputV3
### Entry points
`swapExactInputV3(tokenIn, tokenOut, fee, amountIn, amountOutMinimum, deadline)` — `onlyOperator whenNotPaused nonReentrant`, returns `amountOut`.
### Flow
1. V3-only first: neither side is native ETH (`NativeNotSupported`). Then `_prepareSwap` (shared with V4):
   - checks: `tokenIn == stableToken || tokenOut == stableToken` (else `PairNotAllowed`); the other side in `allowedToken` (else `TokenNotAllowed`; this also rejects stable → stable, since the stable is never in `allowedToken`); `amountIn > 0`, `amountOutMinimum > 0`, `block.timestamp <= deadline`; `_allowedPool[stableToken][token][fee][V3_POOL]` (else `PoolNotAllowed`);
   - **buy** (`tokenIn == stableToken`): only after every check passes, `IERC4626(morphoVault).withdraw(amountIn, address(this), address(this))` → emit `MorphoWithdrawn(amountIn, shares)`. So a buy is **one tx** and the stable never sits idle.
   Then `amountIn <= balance(tokenIn)` (`InsufficientBalance` — reachable for sells; a buy always has exactly `amountIn` after the withdraw).
2. Snapshot `balance(tokenOut)`.
3. `forceApprove(router, amountIn)` → `exactInputSingle({recipient: address(this), sqrtPriceLimitX96: 0, ...})` → `forceApprove(router, 0)`.
4–6. `_settleSwap` (shared with V4): `amountOut = balance(tokenOut) after − before`; require `>= amountOutMinimum`; add the stable side (buy: `amountIn`, sell: `amountOut`) to today's volume, revert `DailyVolumeExceeded` past the cap (§6); emit `Swapped`;
   if `tokenOut == stableToken` (sell): `_supplyToMorpho(amountOut)` + emit `MorphoDeposited`. Only the proceeds are supplied; pre-existing idle stable is untouched.
### Security
- Invariant #2: `recipient` hardcoded. Invariant #3: approve exact → reset 0.
- The router's return value is not trusted; output is measured by balance delta (catches a lying router).
- Slippage is the bot's responsibility (QuoterV2 off-chain); the contract only enforces `amountOutMinimum > 0`. **Accepted risk:** a stolen operator key can sandwich the vault's own swaps (`minOut = 1`), but only with real capital across several txs because 7702-delegated callers are rejected, and a sandwiched **buy** spends at most `dailyVolumeCap` of stable per day (§6); a sandwiched **sell** is not bounded by the cap — see [security-safety §5](security-safety.md#5-accepted-risks).
- The stable-side rule + the pool whitelist (§3) limit the operator to exactly the pools the signers listed — it cannot route through a pool it created itself.
### Edge cases
- SwapRouter02 on Base has **no `deadline`** field; the vault checks it.
- Decimals: USDC 6, WETH 18, cbBTC 8 — amounts are raw token units, nothing assumes 18.
- Buy: idle stable already in the vault (e.g. stable transferred in directly) is **not** used — the swap always pulls `amountIn` from Morpho. Morpho short of `amountIn` → reverts with Morpho's error (`ERC4626ExceededMaxWithdraw`). Put stray idle stable back with `morphoDeposit`.
- Buy whose swap fails (slippage, bad pool, deadline): the whole tx reverts, the stable stays in Morpho. Any failed check reverts before Morpho is touched.

## 3. Pool whitelist (`allowedPool`) — shared with V4
### Purpose
Pins every operator swap to a pool the signers picked. One entry = **one pool** = `(token, fee, tickSpacing)`; the other side is always `stableToken`. Entries are keyed by **epochs**: `_poolId = keccak256(stableEpoch, token, _tokenEpoch[token], fee, tickSpacing)`. `stableEpoch` is bumped by every `ChangeStableToken`, `_tokenEpoch[token]` by every `RemoveToken(token)`. So an entry only ever means the pool against the stable that was current when it was added, and dies for good once the stable changes (even if it later changes back) or the token is removed (even if it is re-added):
- `tickSpacing == V3_POOL` (0) → the Uniswap V3 pool (stable, token, fee). V3 has one pool per (pair, fee), so this is exact.
- `tickSpacing >= 1` → the **hookless** V4 pool (stable, token, fee, tickSpacing). With `hooks = address(0)` hardcoded, this is exactly one V4 PoolId.

Signers enter readable numbers (token address, fee, spacing) — no PoolId / pool address lookup needed; the contract derives the pool itself.
### Why one entry per pool (not separate fee / tick-spacing lists)
With independent fee and tick-spacing lists the operator could combine any allowed fee with any allowed spacing for any allowed token (e.g. USDC/WETH `500/60`). Those combos are usually **not real pools**, and V4 pool creation is permissionless: someone holding a stolen operator key could initialize such a pool at a rigged price with dust liquidity, swap the whole vault into it with `minOut = 1`, then pull the liquidity — draining the vault with no capital. Whitelisting the full triple closes that path: only listed pools are reachable.
### Entry points
- Constructor `_pools[]` (`PoolConfig{token, fee, tickSpacing}`; deploy script: env `POOL_TOKENS` / `POOL_FEES` / `POOL_TICK_SPACINGS`). Duplicate entry → `Duplicate`.
- Proposal `SetAllowedPool(address token, uint24 fee, int24 tickSpacing, bool allowed)` / helper `proposeSetAllowedPool(...)` — `onlySigner`, threshold.
- View: `allowedPool(token, fee, tickSpacing)` — always answers for the **current** epochs. There is **no on-chain list** (it would push the contract over the 24,576-byte EIP-170 limit); rebuild the full set from `PoolAllowed(stable, token, fee, tickSpacing, allowed)` events, dropping every entry followed by a later `StableTokenChanged` (any) or `TokenAllowed(token, false)` (same token), e.g. `cast logs --address <vault> "PoolAllowed(address,address,uint24,int24,bool)" --from-block <deploy block>` or the basescan Events tab.
### Flow
`_setAllowedPool`:
- add (`allowed = true`): `_checkPoolConfig` → `token != stableToken` (`StableNotTradable`), `1 <= fee <= MAX_POOL_FEE (1_000_000)` (`InvalidFee`; also excludes the V4 dynamic-fee flag), `0 <= tickSpacing <= 32767` (`InvalidTickSpacing`), no V3 entry for native ETH (`NativeNotSupported`); not already listed under the current epochs (`Duplicate`) → set.
- remove (`allowed = false`): must be listed under the current epochs (`NotFound` — a dead entry from an old epoch counts as not listed) → unset.
- emit `PoolAllowed(stableToken, token, fee, tickSpacing, allowed)`.
`_checkPoolConfig` also runs at propose time for adds; `Duplicate` / `NotFound` are checked at execution.
Swaps: V3 checks `_allowedPool[_poolId(token, fee, V3_POOL)]`; V4 rejects `tickSpacing < 1` first (so the V3 marker 0 can never unlock a V4 swap), then checks `_allowedPool[_poolId(token, fee, tickSpacing)]`. Both → `PoolNotAllowed`.
### Security
- The entry is per token: listing `(WETH, 3000, 60)` does **not** unlock `(cbBTC, 3000, 60)`; a V4 entry does not unlock the V3 pool with the same fee (and vice versa).
- **Signers must only list pools that already exist with real liquidity.** A listed-but-missing pool can still be created and seeded by anyone. The deploy script checks every V3 entry exists (`UNI_V3_FACTORY.getPool`); V4 entries must be checked on a fork / the Uniswap UI.
- Adding a pool does not require the token to be in `allowedToken` yet (swaps check both), so `AddToken` and `SetAllowedPool` can be proposed in parallel. **`RemoveToken` kills the token's pool entries for good** (bumps `_tokenEpoch[token]`): a later `AddToken` opens no pool until signers re-vet and list each pool again — a stale entry could point at a pool that lost its liquidity meanwhile (cheap to manipulate with a leaked operator key). (`test_Security_RemoveTokenThenAddTokenDoesNotRevivePools`)
- **`ChangeStableToken` drops every entry** ([morpho-integration §5](morpho-integration.md#5-changestabletoken)): it bumps `stableEpoch`, so every old entry dies and the `(newStable, token)` pools — which nobody vetted and may not even exist yet (a stolen operator key could create and seed one) — are never swappable until signers list them again with `SetAllowedPool` — and a `SetAllowedPool` proposed before the switch is expired, so it can't land under the new stable either. Switching back to an old stable does **not** revive its old entries (`test_Security_ChangeStableTokenBackDoesNotReviveOldPools`).
- No per-tx cap, no TWAP check (by design, spec §7); total volume per day is capped (§6) — sandwich on a listed pool remains a risk: bounded by the cap for buys only ([security-safety §5](security-safety.md#5-accepted-risks)).
### Edge cases
- Default list (`.env.example`, checked on a Base fork 2026-10-08): V3 USDC/WETH 500, V3 USDC/cbBTC 500, V4 USDC/WETH 500/10 and 3000/60, V4 USDC/cbBTC 500/10. Native ETH: add `(address(0), 500, 10)` together with `AddToken(address(0))`.
- WETH/cbBTC pools exist but are never usable — stable-side rule (`PairNotAllowed`).

## 4. Atomic approvals & output measurement
See §1 steps 3–4. After every call, allowance of the vault to the router is 0 for every token.

## 5. Changing the router (`ChangeUniV3Router`)
### Purpose
Lets the signers point swaps at a new SwapRouter02 (e.g. Uniswap redeploys, or a router is found to be compromised) without redeploying the vault.
### Entry points
Proposal `ChangeUniV3Router(address newRouter)` / `proposeChangeUniV3Router` — `onlySigner`, executes only at threshold.
### Flow
`_validate`: `newRouter != 0`, `!= uniV3Router` → at threshold `_changeUniV3Router`: same checks again, `uniV3Router = newRouter`, emit `UniV3RouterChanged(old, new)`. The next `swapExactInputV3` reads the new address.
### Security
- No allowance migration is needed: approvals are always reset to 0 in the swap tx (invariant #3), so the old router has no power over vault funds after the switch (tested: `test_Security_OldRouterHasNoPowerAfterChange`).
- The new router is **not validated on-chain**. Operator swaps hand `tokenIn` to it, so a malicious router could keep it — signers must verify the address (Uniswap docs + basescan) before approving. Same trust level as `AddWithdrawAddress` + `WithdrawBatch`.
- Operators / outsiders cannot propose or vote; one signer below threshold cannot change it (`test_Security_ChangeProtocolAddressesNeedThreshold`).
### Edge cases
- The new router must use the SwapRouter02 `ExactInputSingleParams` (no `deadline` field); a SwapRouter V1-style router would make every swap revert (nothing lost — just pause / change back).

## 6. Daily volume cap (`dailyVolumeCap`) — shared with V4
### Purpose
Bounds how much value a leaked operator key can burn per day. The pool whitelist alone does not stop two cheap attacks: (a) **fee churn** — buy/sell back and forth at fair prices, paying pool fees each time (collected by the attacker's own tight-range LP), with no capital, no price deviation for a price monitor to spot, and hundreds of txs per minute on Base; (b) **sandwich** on a listed pool. The cap bounds (a) and buy-side (b), because buys count the stable sold. **Sells are not bounded**: a sell counts the stable *received*, so dumping all WETH / cbBTC into a pushed pool with `minOut = 1` uses only a few raw units of the cap (PoC 2026-10-15) — open risk, see [security-safety §5](security-safety.md#5-accepted-risks).
### Entry points
- Constructor `_dailyVolumeCap` (raw stable units; deploy script default `600 * 10**decimals` = 600 USDC = `600e6`, env `DAILY_VOLUME_CAP`).
- Proposal `SetDailyVolumeCap(uint256 cap)` / helper `proposeSetDailyVolumeCap(cap)` — `onlySigner`, threshold. Payload must be exactly 32 bytes (`BadArrayLength`). Any value is valid; `0` blocks every swap.
- Views: `dailyVolumeCap()`, `volumeDay()`, `dailyVolumeUsed()`. Remaining today = `volumeDay == block.timestamp / 1 days ? cap - used : cap` (a lowered cap can be below `used` → 0 left).
- Event `DailyVolumeCapChanged(oldCap, newCap)` (constructor, proposal, and `ChangeStableToken` → 0). Error `DailyVolumeExceeded`.
### Flow
In `_settleSwap` (every V3 and V4 swap, after the output check): `amount` = the stable side — `amountIn` for a buy (stable sold), the measured `amountOut` for a sell (stable received). `_useDailyVolume(amount)`: `day = block.timestamp / 1 days`; `used = (day == volumeDay ? dailyVolumeUsed : 0) + amount`; `used > dailyVolumeCap` → revert `DailyVolumeExceeded`; else store `volumeDay = day`, `dailyVolumeUsed = used`.
### Security
- **Both directions count** — counting only buys would leave the churn loop open. V3 and V4 share one budget.
- A swap that would exceed the cap reverts as a whole: on a buy the stable stays in Morpho.
- `ChangeStableToken` sets the cap and today's usage to 0 (amounts are in old-stable units; decimals may differ), so swaps are blocked until signers pass a `SetDailyVolumeCap` for the new stable ([morpho-integration §5](morpho-integration.md#5-changestabletoken)).
- Invariant #14 (`test_Security_OperatorChurnBoundedByDailyCap`).
### Edge cases
- Calendar UTC day, not a rolling 24 h window: up to 2× the cap can move around 00:00 UTC.
- Reaching the cap exactly is allowed; one more unit reverts.
- Lowering the cap below today's usage blocks swaps until the next UTC day.
- The bot should read the remaining budget before sizing a swap (a revert only wastes gas).

## Related
- [morpho-integration.md](morpho-integration.md)
- [swap-v4.md](swap-v4.md)
- [security-safety.md](security-safety.md)
