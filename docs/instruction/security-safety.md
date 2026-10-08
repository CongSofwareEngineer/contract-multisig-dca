# Security & Safety
> Last updated: 2026-10-08

## Overview
How the vault keeps funds safe even if the operator key is stolen.
Sub-logics:
1. Pause / Unpause
2. Token whitelist & anti-junk-token
3. WithdrawBatch
4. The §10 invariants and their tests
5. Accepted risks

## Shared
- Code: `pause()` + `Unpause` in `src/vault/DCAVaultProposals.sol`; `whenNotPaused` / `onlyOperator` modifiers and all state in `src/vault/DCAVaultStorage.sol`; token whitelist setters in `src/vault/DCAVaultRoles.sol`.
- Storage: `paused`, `allowedToken`, `_allowedTokenList` (internal mirror for views, no public getter).
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
- Swaps check both tokens, and one side must be USDC (no token ↔ token); `WithdrawBatch` checks every token.
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
### Security
Every token that leaves the contract goes to an address in `isWithdrawAddress` (added only by a signer proposal); everything else fails. The only other outflows are protocol interactions whose output comes back to the vault (router swap — router changeable only at threshold, Morpho deposit) and `ChangeMorphoVault`, which sends all USDC to whatever vault a threshold of signers approved — not validated on-chain, so signers must verify it ([morpho-integration §4](morpho-integration.md#4-changemorphovault-migration)).
### Edge cases
Any failure reverts the whole batch. Duplicate tokens in one batch are processed in order (second `max` of the same token will revert with `InsufficientBalance`).

## 4. The §10 invariants and their tests
All in `test/DCAVault.security.t.sol`:

| # | Invariant | Test(s) |
|---|---|---|
| 1 | Operator can't move tokens out | `testFuzz_Invariant1_OperatorCannotExtract`, `..._OperatorCannotUseSignerFunctions`, `..._RouterCannotPullMoreThanAmountIn`, `..._LyingRouterIsCaughtByBalanceDelta`, `..._V4RouterCannotPullMoreThanAmountIn`, `..._V4ShortOutputIsCaughtByBalanceDelta` (fuzz covers V3 + V4) |
| 2 | Outputs go to `address(this)` | `test_Invariant2_*` |
| 3 | Allowances 0 after each tx (router, Morpho, ERC20 → Permit2, Permit2 → UniversalRouter) | `test_Invariant3_AllowancesZeroAfterEveryFlow`, `test_Invariant3_V4Permit2AllowanceExpiresThisBlock` (+ fork `_assertNoAllowances` / `_assertNoPermit2Allowances`) |
| 4 | Withdraw only via approved batch to whitelist | `test_Invariant4_*`, `test_Security_ChangeMorphoVaultRejectsFakeVault` |
| 5 | Signers ≥ 2 | `test_Invariant5_*` (incl. concurrent removals) |
| 6 | Removed signer's votes don't count | `test_Invariant6_*`, `test_Reject_RemovedSignerRejectionNotCounted` |
| 7 | Expired/executed/cancelled never execute | `test_Invariant7_*` |
| 8 | Pause blocks operator; unpause by proposal | `test_Invariant8_*` |
| 9 | No delegatecall/selfdestruct/callcode | `test_Invariant9_NoDelegatecallOrSelfdestruct` (bytecode opcode scan) |
| 10 | Rejects ETH | `test_Invariant10_RejectsEth` |
| 11 | Only USDC in; whitelist enforced | `test_Invariant11_*` |
| 12 | Junk tokens harmless | `test_Invariant12_JunkTokenDoesNotAffectAnyFlow` |
| — | Reentrancy | `test_Security_ReentrancyBlocked` |
| — | One signer cannot cancel others' proposals | `test_Security_SingleSignerCannotCancelOthers` |
| — | Swap needs a USDC side | `testFuzz_Security_SwapNeedsUsdcSide` |
| — | Protocol addresses change only at threshold | `test_Security_ChangeProtocolAddressesNeedThreshold`, `test_Security_ChangeMorphoVaultNeedsThreshold` |
| — | Old router keeps no allowance after a switch | `test_Security_OldRouterHasNoPowerAfterChange` |
| — | Every signer function checks the role (incl. `reject`, `cancel`, `pause`) | `test_Invariant1_OperatorCannotUseSignerFunctions`, `test_Revert_Cancel_ProposerNoLongerSigner` |

## 5. Accepted risks
Found in the 2026-10-08 security review; the owner chose to keep the spec behavior. Full list: `DCA_VAULT_SPEC.md` §16.
1. **Operator sandwich.** The contract only checks `amountOutMinimum > 0`. A stolen operator key can move the pool price, then call `withdrawAndSwapV3(all USDC, minOut = 1)` / `swapExactInputV4(…, minOut = 1)` (or sell all WETH / cbBTC) and back-run — tokens never leave directly, but most of the value does. `allowedFee` (and `allowedTickSpacing` for V4) are global, so the operator may pick a thinner pool. Mitigation today: any signer `pause()`s on the first suspicious `Swapped` event; keep few operators; monitor.
2. **`ChangeMorphoVault` is all-or-nothing.** A paused / illiquid / broken old vault makes the full `redeem` revert, so the vault cannot be switched; deposits and sell proceeds keep flowing into it. Mitigation: `pause()` to stop sells.
3. **2 signers ⇒ threshold 1.** One leaked signer key alone can whitelist an address and withdraw everything, add signers, or switch the router. Deploy with ≥ 3 signers.
4. **Stale `Unpause` proposals** from an earlier pause stay approvable for 7 days. Cancel / reject leftovers.
5. **Protocol addresses are not validated on-chain** (Morpho vault, router, Permit2, UniversalRouter): a threshold proposal can set any address. Same trust as `AddWithdrawAddress` + `WithdrawBatch`.

## Related
- [proposal-system.md](proposal-system.md)
- [roles-multisig.md](roles-multisig.md)
- [swap-v3.md](swap-v3.md)
