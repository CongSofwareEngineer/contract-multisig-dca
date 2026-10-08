# Morpho Integration
> Last updated: 2026-10-08

## Overview
Idle USDC always sits in a MetaMorpho (ERC-4626) vault to earn yield. The vault only pulls out exactly what it needs.
Sub-logics:
1. `depositAndSupply` (anyone)
2. `morphoDeposit` (operator)
3. `morphoWithdraw` (operator)
4. `ChangeMorphoVault` migration (proposal)

## Shared
- Code: `src/vault/DCAVaultMorpho.sol` (`depositAndSupply`, `morphoDeposit` / `morphoWithdraw`, `_prepareUsdc`, `_changeMorphoVault`, `totalUsdc`, `getBalances`).
- Storage: `morphoVault` (mutable only via proposal), immutable `usdc`.
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
### Entry points
Proposal `ChangeMorphoVault(address newVault)` / `proposeChangeMorphoVault`.
### Flow
1. Check `newVault != 0`, `!= current`, `IERC4626(newVault).asset() == usdc` (also checked at propose time).
2. `redeem(all shares)` from the old vault into the contract.
3. Set `morphoVault = newVault`.
4. Supply the **entire USDC balance** (redeemed + any idle USDC) to the new vault with the atomic approve pattern.
5. Emit `MorphoVaultChanged(old, new, migrated)`.
### Security
No standing allowance to either vault after the call (tested on fork: Steakhouse → Gauntlet USDC Prime).
### Edge cases
If old vault has no liquidity for a full redeem, the whole proposal reverts and nothing changes. Zero balance → no deposit call, still switches.

## Related
- [swap-v3.md](swap-v3.md) — `withdrawAndSwapV3`, sell auto-deposit
- [security-safety.md](security-safety.md) — WithdrawBatch pulling USDC from Morpho
