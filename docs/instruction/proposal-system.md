# Proposal System
> Last updated: 2026-10-08

## Overview
Every signer action except `pause()` goes through a proposal: create → collect votes → auto-execute when valid votes ≥ threshold.
Sub-logics:
1. Lifecycle (propose / approve / execute / cancel)
2. Vote counting & expiry
3. Proposal types and payloads
4. Helper `proposeXxx` functions

## Shared
- Code: `src/vault/DCAVaultProposals.sol` (pause, propose / approve / cancel, `_validate`, `_execute`, `_withdrawBatch`); `ProposalType` / `Proposal` in `src/vault/DCAVaultStorage.sol`.
- Storage: `proposals[id]` (`pType, data, proposer, createdAt, executed, cancelled`), `hasApproved[id][signer]`, `proposalCount`.
- Constant: `PROPOSAL_TTL = 7 days`.
- Events: `ProposalCreated(id, pType, proposer)`, `ProposalApproved(id, signer)`, `ProposalExecuted(id)`, `ProposalCancelled(id)`.
- Errors: `ProposalNotFound`, `ProposalAlreadyExecuted`, `ProposalIsCancelled`, `ProposalExpired`, `AlreadyApproved`, `NotProposer`.
- Functions `propose`, `approve`, helpers are `onlySigner nonReentrant` (execution may call Morpho / tokens).

## 1. Lifecycle
### Entry points
- `propose(ProposalType, bytes data)` → id. Proposer auto-approves.
- `approve(id)` — any signer, once.
- `cancel(id)` — only the proposer, only before execution.
- `getProposal(id)` → `(pType, data, validApprovals, threshold, executed, cancelled, expired)`.
### Flow
1. `_propose` runs `_validate(pType, data)` (decodes payload, rejects obviously invalid input), stores the proposal with id `++proposalCount` (**ids start at 1**), emits `ProposalCreated`, then calls `_approve`.
2. `_approve` checks: exists, not executed, not cancelled, not expired, sender has not voted. Records vote, emits `ProposalApproved`.
3. Re-count valid votes; if ≥ `getThreshold()`: set `executed = true` **before** any external call, dispatch to the handler, emit `ProposalExecuted`.
4. If the handler reverts, the whole approve tx reverts — the vote is not recorded and the proposal stays pending (can be retried later while not expired).
### Security
Invariant #7: expired / executed / cancelled proposals can never execute. Checks-effects-interactions on `executed`.
### Edge cases
- Proposals (incl. `WithdrawBatch`) work while paused.
- A proposal is executable up to and including `createdAt + 7 days`; one second later it is expired.

## 2. Vote counting & expiry
`_countValidApprovals(id)` loops `signers[]` and counts `hasApproved[id][s]`. Only **current** signers count (invariant #6). Removed signers also cannot call `approve` (they fail `onlySigner`).

## 3. Proposal types and payloads
Each handler re-validates against live state at execute time (state may have changed since propose).

| ProposalType | `data` (abi.encode) | Constraints | Handler doc |
|---|---|---|---|
| `WithdrawBatch` | `(address[] tokens, uint256[] amounts, address to)` | `to` whitelisted; tokens whitelisted; equal non-empty arrays; amounts > 0; `type(uint256).max` = all | [security-safety §3](security-safety.md#3-withdrawbatch) |
| `AddWithdrawAddress` | `address` | ≠ 0, not already | [roles-multisig §3](roles-multisig.md#3-withdraw-addresses) |
| `RemoveWithdrawAddress` | `address` | must exist | same |
| `AddSigner` | `address` | ≠ 0, not signer, not operator | [roles-multisig §1](roles-multisig.md#1-signers) |
| `RemoveSigner` | `address` | ≥ 2 remain | same |
| `AddOperator` | `address` | ≠ 0, not operator, not signer | [roles-multisig §2](roles-multisig.md#2-operators) |
| `RemoveOperator` | `address` | must exist | same |
| `ChangeMorphoVault` | `address newVault` | `asset() == usdc`, ≠ current | [morpho-integration §4](morpho-integration.md#4-changemorphovault-migration) |
| `AddToken` / `RemoveToken` | `address` | USDC cannot be removed | [security-safety §2](security-safety.md#2-token-whitelist--anti-junk-token) |
| `SetAllowedFee` | `(uint24 fee, bool allowed)` | fee > 0 | [swap-v3 §3](swap-v3.md#3-allowedfee) |
| `Unpause` | empty bytes | must be paused at execute | [security-safety §1](security-safety.md#1-pause--unpause) |

There is **no** proposal that approves arbitrary tokens / spenders.

## 4. Helper `proposeXxx` functions
`proposeWithdrawBatch`, `proposeAddWithdrawAddress`, `proposeRemoveWithdrawAddress`, `proposeAddSigner`, `proposeRemoveSigner`, `proposeAddOperator`, `proposeRemoveOperator`, `proposeChangeMorphoVault`, `proposeAddToken`, `proposeRemoveToken`, `proposeSetAllowedFee`, `proposeUnpause`.
They ABI-encode the payload and call internal `_propose` — never `this.propose()`, which would make `msg.sender` the vault itself (tested: `proposer` is the calling signer).

## Related
- [roles-multisig.md](roles-multisig.md)
- [security-safety.md](security-safety.md)
- [morpho-integration.md](morpho-integration.md)
