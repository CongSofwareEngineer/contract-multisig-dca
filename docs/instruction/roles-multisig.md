# Roles & Multisig
> Last updated: 2026-10-08

## Overview
DCAVault has three on-chain roles: **signers** (multisig owners), **operators** (bot hot keys) and **anyone**.
Plus a whitelist of **withdraw addresses** — the only places tokens can ever be sent.
Sub-logics:
1. Signers
2. Operators
3. Withdraw addresses
4. Threshold

## Shared
- Code: `src/vault/DCAVaultRoles.sol` (setters, `getSigners`, `getThreshold`); state + modifiers in `src/vault/DCAVaultStorage.sol`.
- Storage: `isSigner`, `signers[]`, `isOperator`, `isWithdrawAddress`.
- Constant: `MIN_SIGNERS = 2`.
- Modifiers: `onlySigner`, `onlyOperator`.
- Events: `SignerAdded/Removed`, `OperatorAdded/Removed`, `WithdrawAddressAdded/Removed`.
- Errors: `NotSigner`, `NotOperator`, `ZeroAddress`, `Duplicate`, `RoleConflict`, `TooFewSigners`, `NotFound`.

| Role | Can do |
|---|---|
| signer | propose / approve / reject, cancel own proposals (only while still a signer), `pause()` alone |
| operator | `swapExactInputV3`, `withdrawAndSwapV3`, `swapExactInputV4`, `morphoDeposit`, `morphoWithdraw` (only while not paused) |
| anyone | `depositAndSupply` (`stableToken` only), views |

## 1. Signers
### Purpose
Cold / hardware wallets of the owner. All config changes and all withdrawals need signer votes.
### Entry points
- Constructor `_signers[]` (≥ 2).
- Proposals `AddSigner(address)`, `RemoveSigner(address)` — see [proposal-system](proposal-system.md).
- `getSigners()` view.
### Flow
`_addSigner`: non-zero, not already signer, not operator → `isSigner = true`, push to `signers`, emit `SignerAdded`.
`_removeSigner`: must be signer, `signers.length - 1 >= MIN_SIGNERS` → swap-and-pop from `signers`, emit `SignerRemoved`.
### Security
- Invariant #5: signer count can never drop below 2 — checked at propose time **and** at execute time, so two concurrent `RemoveSigner` proposals cannot bypass it.
- A signer can never also be an operator (checked in constructor and both Add proposals).
### Edge cases
- Removing a signer instantly removes their approvals and rejections from every pending proposal (votes are re-counted from `signers[]`). If the same address is re-added later, its old flags count again ([proposal-system §2](proposal-system.md#2-vote-counting-expiry--rejection)).
- Deploying with exactly 2 signers gives threshold 1: each signer acts alone (also true after 3 → 2 removals).
- Array order changes after removal (swap-and-pop); don't rely on index.

## 2. Operators
### Purpose
Hot key used by the off-chain bot. Pays its own gas. Can only trade stable ↔ whitelisted tokens and move the stable in/out of Morpho; it can never send tokens anywhere else.
### Entry points
Constructor `_operators[]` (may be empty); proposals `AddOperator`, `RemoveOperator`.
### Flow
`_addOperator`: non-zero, not already operator, not signer. `_removeOperator`: must be operator. Removing every operator is allowed (bot fully off).
### Security
Invariant #1 — see [swap-v3](swap-v3.md) and [security-safety](security-safety.md).
### Edge cases
There is no `bot` role; the bot is just an operator key.

## 3. Withdraw addresses
### Purpose
Only destinations allowed for `WithdrawBatch`.
### Entry points
Constructor `_withdrawAddresses[]`; proposals `AddWithdrawAddress` (non-zero), `RemoveWithdrawAddress`.
### Security
Invariant #4. Every outgoing transfer must go to an address in `isWithdrawAddress`; anything else reverts. `to` is re-checked at execute time: removing an address cancels pending withdrawals to it in effect.

## 4. Threshold
### Purpose
Number of valid approvals needed to execute a proposal.
### Entry points
`getThreshold()` = `(signers.length + 1) / 2` (≥ 50 %, rounded up).

| signers | 2 | 3 | 4 | 5 |
|---|---|---|---|---|
| threshold | 1 | 2 | 2 | 3 |

### Edge cases
With 2 signers the threshold is 1, so a proposal executes **immediately** in `propose` (the proposer's auto-vote is enough). Threshold is evaluated live at each approval.

## Related
- [proposal-system.md](proposal-system.md)
- [security-safety.md](security-safety.md)
