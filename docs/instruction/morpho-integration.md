# Morpho Integration
> Last updated: 2026-10-08

## Overview
The vault has **one stablecoin**, `stableToken` (USDC today), kept separate from the tradable-token list. Idle stable always sits in a Morpho vault (ERC-4626: Vault V2 or MetaMorpho V1) to earn yield. **Only the stable goes to Morpho**. Bought tokens (WETH, cbBTC, native ETH) stay idle in the contract and are never staked (APR too low to be worth it). The contract simply supplies to / withdraws from the address stored in `morphoVault`. It does **not** validate that address on-chain (no factory or `asset()` check, owner decision). The address can only be changed by a threshold `ChangeMorphoVault` or `ChangeStableToken` proposal. The vault only pulls out exactly what it needs.
Sub-logics:
1. `depositAndSupply` (anyone)
2. `morphoDeposit` (operator)
3. `morphoWithdraw` (operator)
4. `ChangeMorphoVault` migration (proposal)
5. `ChangeStableToken` (proposal)

## Shared
- Code: `src/vault/DCAVaultMorpho.sol` (`depositAndSupply`, `morphoDeposit` / `morphoWithdraw`, `_prepareStable`, `_changeMorphoVault`, `_changeStableToken`, `totalStable`, `getBalances`, native-aware helpers `_balanceOf` / `_sendToken`).
- Storage: `stableToken` and `morphoVault` (set in constructor, then mutable only via threshold proposals).
- "Is this the stable?" is always an address compare against `stableToken`. The stable is never in `allowedToken`, so the two lists cannot overlap.
- Internal: `_supplyToMorpho(amount)` = `forceApprove(vault, amount)` → `deposit(amount, address(this))` → `forceApprove(vault, 0)`; `_withdrawFromMorpho(amount)` = `withdraw(amount, address(this), address(this))`.
- Events: `Deposited(from, amount, shares)`, `MorphoDeposited(assets, shares)`, `MorphoWithdrawn(assets, shares)`, `MorphoVaultChanged(old, new, migratedAssets)`, `StableTokenChanged(oldStable, newStable, oldMorphoVault, newMorphoVault, sweptAmount)`.
- Views: `totalStable()` = idle stable + `convertToAssets(shares)`; `getBalances()` → `(stableIdle, stableInMorpho, tokens[], balances[])` (see [security-safety §2](security-safety.md#2-stable--tradable-tokens--anti-junk-token)).

## 1. depositAndSupply
### Entry points
`depositAndSupply(uint256 amount)` — anyone, `nonReentrant`, **not** paused-gated.
### Flow
`safeTransferFrom(msg.sender → vault, amount)` of `stableToken` → `_supplyToMorpho(amount)` → emit `Deposited`.
### Security
No token parameter, so only the stable can enter (invariant #11). Allowance to Morpho is reset to 0 (invariant #3).
### Edge cases
`amount == 0` → `ZeroAmount`. Stable sent by plain `transfer` stays idle until an operator calls `morphoDeposit`. Amounts are in the stable's own decimals (USDC: 6).

## 2. morphoDeposit
`morphoDeposit(uint256 amount)` — `onlyOperator whenNotPaused nonReentrant`. Requires `0 < amount <= idle stable`, then `_supplyToMorpho`, emit `MorphoDeposited`.

## 3. morphoWithdraw
`morphoWithdraw(uint256 amount)` — `onlyOperator whenNotPaused nonReentrant`. Withdraws exactly `amount` stable; `receiver` and `owner` are hardcoded `address(this)` (invariant #2). Emits `MorphoWithdrawn`. No approval needed (vault burns its own shares).
Not needed for buys: `swapExactInputV3` / `swapExactInputV4` with `tokenIn == stableToken` withdraw exactly `amountIn` themselves (same internal `_withdrawFromMorpho`, same event) and ignore idle stable — see [swap-v3 §1](swap-v3.md#1-swapexactinputv3).

## 4. ChangeMorphoVault migration
### Purpose
Point the vault at a different Morpho vault for the **same** stable and move all of the stable there.
### Entry points
Proposal `ChangeMorphoVault(address newVault)` / `proposeChangeMorphoVault`. It is `onlySigner` to propose/approve and executes only when valid approvals ≥ `getThreshold()`. Operators and outsiders cannot propose or vote; one signer alone (below threshold) cannot change it.
### Flow
1. Validate `newVault != 0` and `!= current` (`SameMorphoVault`) at propose and execute. **No factory / `asset()` check**: the address is whatever the signers approved.
2. `redeem(all shares)` from the old vault into the contract.
3. Set `morphoVault = newVault`.
4. Supply the **entire stable balance** (redeemed + any idle stable) to the new vault with the atomic approve pattern.
5. Emit `MorphoVaultChanged(old, new, migrated)`.
### Security
- Only a threshold of signers can change the address (tested: `test_Security_ChangeMorphoVaultNeedsThreshold`).
- No standing allowance to either vault after the call (tested on fork: Steakhouse Vault V2 → Gauntlet USDC Prime).
- Migration sends **all** stable to `newVault`, and nothing on-chain checks that it is a real Morpho vault. Signers must verify `newVault` before approving: deployed by Morpho, `asset()` = stable, who the curator/owner is.
### Edge cases
- If the old vault has no liquidity for a full redeem (or is paused / broken), the whole proposal reverts and nothing changes. The vault cannot leave a broken Morpho vault until it is redeemable again. Owner-accepted risk, see [security-safety §5](security-safety.md#5-accepted-risks). With a zero balance there is no deposit call, but the vault still switches.
- A `newVault` that isn't ERC-4626 / doesn't take the stable makes `deposit` revert, so the whole execution reverts and the old vault is kept.
- Constructor: `morphoVault` is only checked for `!= 0`; the deploy script pre-flights `asset() == STABLE_TOKEN` off-chain.

## 5. ChangeStableToken
### Purpose
Replace the stable itself (e.g. USDC → another stablecoin) together with its Morpho vault. Owner rule: **everything in the old stable must be withdrawn before the switch**.
### Entry points
Proposal `ChangeStableToken(address newStable, address newVault, address to)` / `proposeChangeStableToken(newStable, newVault, to)`. It is `onlySigner` and needs the threshold. `ProposalType.ChangeStableToken` is appended at the end of the enum.
### Flow (`_changeStableToken`)
1. Checks (at propose and again at execute): `newStable`, `newVault != 0` (`ZeroAddress`); `newStable != stableToken` (`SameAddress`); `newVault != morphoVault` (`SameMorphoVault`); `newStable` not in `allowedToken` (`StableNotTradable`); `to` in `isWithdrawAddress` (`WithdrawAddressNotAllowed`).
2. `redeem(all shares)` of the old Morpho vault → emit `MorphoWithdrawn`.
3. Send **the whole old-stable balance** (redeemed + idle) to `to` → emit `Withdrawn`.
4. Set `stableToken = newStable`, `morphoVault = newVault` → emit `StableTokenChanged(..., swept)`.
### Security
- The sweep happens **inside** the proposal rather than as a "balance must be 0" precondition. Otherwise anyone could block the change forever by donating 1 wei of old stable or calling `depositAndSupply`. Dust that arrives between propose and execute is simply swept too (`test_Proposal_ChangeStableTokenCannotBeGriefedByDust`).
- Old stable only ever goes to a whitelisted withdraw address (invariant #4).
- `newVault` is not validated on-chain. Signers must check `asset() == newStable` before approving.
### Edge cases
- After the switch the old stable is just an unlisted token: it can't be swapped or withdrawn (`TokenNotAllowed`) and is ignored like junk. If old stable arrives later, whitelist it with `AddToken` to withdraw it.
- To make a tradable token the new stable, first `RemoveToken` it.
- All-or-nothing like `ChangeMorphoVault`: if the old vault can't redeem in full, or the old stable blocks the transfer to `to`, nothing changes.
- New stable already sitting idle in the vault stays idle until an operator calls `morphoDeposit`.

## Related
- [swap-v3.md](swap-v3.md) — buy pulls exact stable from Morpho (`swapExactInputV3` / `V4`), sell auto-deposit
- [security-safety.md](security-safety.md) — WithdrawBatch pulling stable from Morpho, stable / tradable token split
- [proposal-system.md](proposal-system.md) — proposal table
