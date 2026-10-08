# Security & Safety
> Last updated: 2026-10-08

## Overview
How the vault keeps funds safe even if the operator key is stolen.
Sub-logics:
1. Pause / Unpause
2. Token whitelist & anti-junk-token
3. WithdrawBatch
4. The §10 invariants and their tests

## Shared
- Storage: `paused`, `allowedToken`, `_allowedTokenList` (private mirror for views).
- Events: `Paused(by)`, `Unpaused()`, `TokenAllowed(token, allowed)`, `Withdrawn(token, to, amount)`.
- Errors: `IsPaused`, `NotPaused`, `TokenNotAllowed`, `CannotRemoveUsdc`, `UsdcNotAllowed`, `WithdrawAddressNotAllowed`, `BadArrayLength`, `InsufficientBalance`.
- `ReentrancyGuard` on every state-changing function that touches an external contract.

## 1. Pause / Unpause
- `pause()` — `onlySigner`, any single signer, immediate. Reverts `IsPaused` if already paused.
- Unpause only via `Unpause` proposal (threshold). Reverts `NotPaused` at execute if not paused.
- While paused: every operator function reverts `IsPaused`. `depositAndSupply` and all proposals (incl. `WithdrawBatch`) still work.
- Why: pausing cannot lose money, so one signer can react instantly to a compromised operator.

## 2. Token whitelist & anti-junk-token
- Constructor `_tokens[]` must include `usdc` (`UsdcNotAllowed` otherwise); duplicates revert.
- `AddToken` / `RemoveToken` proposals; USDC can never be removed.
- Swaps check both tokens; `WithdrawBatch` checks every token.
- Junk tokens transferred in are ignored: no loop over held tokens, no `balanceOf` / call on any non-whitelisted address, no rescue function.
- `getAllowedTokens()` and `getBalances()` → `(usdcIdle, usdcInMorpho, tokens[], balances[])` read only whitelisted tokens.

## 3. WithdrawBatch
### Entry points
Proposal `WithdrawBatch(address[] tokens, uint256[] amounts, address to)` / `proposeWithdrawBatch`.
### Flow (`_withdrawBatch`)
1. `to` must be in `isWithdrawAddress`; arrays equal length, non-empty.
2. For each token: must be whitelisted, amount > 0.
   - **USDC** (`_prepareUsdc`): `max` → redeem all Morpho shares, send whole USDC balance. Otherwise, if idle < amount, withdraw the shortfall from Morpho.
   - **Other tokens**: `max` → whole balance; else require amount ≤ balance.
3. `safeTransfer(to, amount)`, emit `Withdrawn`.
### Edge cases
Any failure reverts the whole batch. Duplicate tokens in one batch are processed in order (second `max` of the same token will revert with `InsufficientBalance`).

## 4. The §10 invariants and their tests
All in `test/DCAVault.security.t.sol`:

| # | Invariant | Test(s) |
|---|---|---|
| 1 | Operator can't move tokens out | `testFuzz_Invariant1_OperatorCannotExtract`, `..._OperatorCannotUseSignerFunctions`, `..._RouterCannotPullMoreThanAmountIn`, `..._LyingRouterIsCaughtByBalanceDelta` |
| 2 | Outputs go to `address(this)` | `test_Invariant2_*` |
| 3 | Allowances 0 after each tx | `test_Invariant3_AllowancesZeroAfterEveryFlow` (+ fork `_assertNoAllowances`) |
| 4 | Withdraw only via approved batch to whitelist | `test_Invariant4_*` |
| 5 | Signers ≥ 2 | `test_Invariant5_*` (incl. concurrent removals) |
| 6 | Removed signer's votes don't count | `test_Invariant6_*` |
| 7 | Expired/executed/cancelled never execute | `test_Invariant7_*` |
| 8 | Pause blocks operator; unpause by proposal | `test_Invariant8_*` |
| 9 | No delegatecall/selfdestruct/callcode | `test_Invariant9_NoDelegatecallOrSelfdestruct` (bytecode opcode scan) |
| 10 | Rejects ETH | `test_Invariant10_RejectsEth` |
| 11 | Only USDC in; whitelist enforced | `test_Invariant11_*` |
| 12 | Junk tokens harmless | `test_Invariant12_JunkTokenDoesNotAffectAnyFlow` |
| — | Reentrancy | `test_Security_ReentrancyBlocked` |

## Related
- [proposal-system.md](proposal-system.md)
- [roles-multisig.md](roles-multisig.md)
- [swap-v3.md](swap-v3.md)
