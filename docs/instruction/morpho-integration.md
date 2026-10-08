# Morpho Integration
> Last updated: 2026-10-08

## Overview
Idle USDC always sits in a Morpho vault (ERC-4626: Vault V2 or MetaMorpho V1) to earn yield. The contract simply supplies to / withdraws from the address stored in `morphoVault` — it does **not** validate that address on-chain (no factory or `asset()` check, owner decision). The address can only be changed by a threshold `ChangeMorphoVault` proposal. The vault only pulls out exactly what it needs.
Sub-logics:
1. `depositAndSupply` (anyone)
2. `morphoDeposit` (operator)
3. `morphoWithdraw` (operator)
4. `ChangeMorphoVault` migration (proposal)

## Shared
- Code: `src/vault/DCAVaultMorpho.sol` (`depositAndSupply`, `morphoDeposit` / `morphoWithdraw`, `_prepareUsdc`, `_changeMorphoVault`, `totalUsdc`, `getBalances`).
- Storage: `morphoVault` (set in constructor, then mutable only via a threshold `ChangeMorphoVault` proposal), immutable `usdc`.
- Internal: `_supplyToMorpho(amount)` = `forceApprove(vault, amount)` → `deposit(amount, address(this))` → `forceApprove(vault, 0)`; `_withdrawFromMorpho(amount)` = `withdraw(amount, address(this), address(this))`.
- Events: `Deposited(from, usdcAmount, shares)`, `MorphoDeposited(assets, shares)`, `MorphoWithdrawn(assets, shares)`, `MorphoVaultChanged(old, new, migratedAssets)`.
- Views: `totalUsdc()` = idle USDC + `convertToAssets(shares)`; `getBalances()` (see [security-safety §2](security-safety.md#2-token-whitelist--anti-junk-token)).

## 1. depositAndSupply
### Entry points
`depositAndSupply(uint256 amount)` — anyone, `nonReentrant`, **not** paused-gated.
### Flow
`safeTransferFrom(msg.sender → vault, amount)` USDC → `_supplyToMorpho(amount)` → emit `Deposited`.
### Security
No token parameter → only USDC can enter (invariant #11). Allowance to Morpho reset to 0 (invariant #3).
### Edge cases
`amount == 0` → `ZeroAmount`. USDC sent by plain `transfer` stays idle until an operator calls `morphoDeposit`.

## 2. morphoDeposit
`morphoDeposit(uint256 amount)` — `onlyOperator whenNotPaused nonReentrant`. Requires `0 < amount <= idle USDC`, then `_supplyToMorpho`, emit `MorphoDeposited`.

## 3. morphoWithdraw
`morphoWithdraw(uint256 amount)` — `onlyOperator whenNotPaused nonReentrant`. Withdraws exactly `amount` USDC; `receiver` and `owner` are hardcoded `address(this)` (invariant #2). Emits `MorphoWithdrawn`. No approval needed (vault burns its own shares).

## 4. ChangeMorphoVault migration
### Purpose
Point the vault at a different Morpho USDC vault and move all USDC there.
### Entry points
Proposal `ChangeMorphoVault(address newVault)` / `proposeChangeMorphoVault` — `onlySigner` to propose/approve, executes only when valid approvals ≥ `getThreshold()`. Operators and outsiders cannot propose or vote; one signer alone (below threshold) cannot change it.
### Flow
1. Validate `newVault != 0` (propose + execute) and `!= current` (execute, `SameMorphoVault`). **No factory / `asset()` check** — the address is whatever the signers approved.
2. `redeem(all shares)` from the old vault into the contract.
3. Set `morphoVault = newVault`.
4. Supply the **entire USDC balance** (redeemed + any idle USDC) to the new vault with the atomic approve pattern.
5. Emit `MorphoVaultChanged(old, new, migrated)`.
### Security
- Only a threshold of signers can change the address (tested: `test_Security_ChangeMorphoVaultNeedsThreshold`).
- No standing allowance to either vault after the call (tested on fork: Steakhouse Vault V2 → Gauntlet USDC Prime).
- Migration sends **all** USDC to `newVault` and nothing on-chain checks it is a real Morpho USDC vault. Signers must verify `newVault` before approving: deployed by Morpho, `asset()` = USDC, who the curator/owner is.
### Edge cases
- If the old vault has no liquidity for a full redeem (or is paused / broken), the whole proposal reverts and nothing changes — the vault cannot leave a broken Morpho vault until it is redeemable again. Owner-accepted risk, see [security-safety §5](security-safety.md#5-accepted-risks). Zero balance → no deposit call, still switches.
- `ChangeMorphoVault` to the current vault is rejected at propose time already (`SameMorphoVault`).
- A `newVault` that isn't ERC-4626 / doesn't take USDC makes `deposit` revert → the whole execution reverts, old vault kept.
- Constructor: `morphoVault` is only checked for `!= 0`; the deploy script pre-flights `asset() == usdc` off-chain.

## Related
- [swap-v3.md](swap-v3.md) — `withdrawAndSwapV3`, sell auto-deposit
- [security-safety.md](security-safety.md) — WithdrawBatch pulling USDC from Morpho
