# Proposal System
> Last updated: 2026-10-15

## Overview
Every signer action except `pause()` goes through a proposal: create → collect votes → auto-execute when valid votes ≥ threshold.
Sub-logics:
1. Lifecycle (propose / approve / reject / execute / cancel)
2. Vote counting, expiry & rejection
3. Proposal types and payloads
4. Helper `proposeXxx` functions

## Shared
- Code: `src/vault/DCAVaultProposals.sol` (pause, propose / approve / cancel, `_validate`, `_execute`, `_withdrawBatch`); `ProposalType` / `Proposal` in `src/vault/DCAVaultStorage.sol`.
- Storage: `proposals[id]` (`pType, data, proposer, createdAt, executed, cancelled`), `hasApproved[id][signer]`, `hasRejected[id][signer]`, `proposalCount`.
- Constant: `PROPOSAL_TTL = 1 days` (24 h).
- Events: `ProposalCreated(id, pType, proposer)`, `ProposalApproved(id, signer)`, `ProposalRejected(id, signer)`, `ProposalExecuted(id)`, `ProposalCancelled(id)`.
- Errors: `ProposalNotFound`, `ProposalAlreadyExecuted`, `ProposalIsCancelled`, `ProposalExpired`, `AlreadyApproved`, `AlreadyVoted`, `NotProposer`, `ProposalTypeMismatch`.
- Functions `propose`, `approve`, helpers are `onlySigner nonReentrant` (execution may call Morpho / tokens). `reject` and `cancel` are `onlySigner` (no external calls). Every state-changing proposal function checks the signer role — a removed signer has no power left over any proposal, including their own.

## 1. Lifecycle
### Entry points
- `propose(ProposalType, bytes data)` → id. Proposer auto-approves.
- `approve(id, pType)` — any signer, once. `pType` = the `ProposalType` the signer expects (enum number, see §3); it must equal the stored type or the call reverts `ProposalTypeMismatch`. The hardware wallet then shows e.g. `approve(12, 1)` = "approve #12, an AddWithdrawAddress" instead of a bare id, and a compromised signer who front-runs to put a different type at the id the others were told to approve gets nothing (`test_Security_ApproveRejectsSwappedProposalType`). Only the **type** is bound, not the payload: before approving, still decode `getProposal(id).data` (e.g. which address an `AddWithdrawAddress` adds). Swaps (`swapExactInputV3/V4`) are operator calls, never voted on, so they have no type.
- `reject(id)` — any signer, once (`onlySigner`); a signer votes approve **or** reject, never both.
- `cancel(id)` — `onlySigner`; only the proposer **while still a signer**, only before execution (`NotSigner` / `NotProposer`).
- `getRejections(id)` → valid rejection count.
- `getProposal(id)` → `(pType, data, validApprovals, threshold, executed, cancelled, expired)`.
### Flow
1. `_propose` runs `_validate(pType, data)` (decodes payload, rejects obviously invalid input), stores the proposal with id `++proposalCount` (**ids start at 1**), emits `ProposalCreated`, then calls `_approve`. It never touches other pending proposals.
2. External `approve` first checks `proposals[id].pType == pType` (`ProposalTypeMismatch`; a missing id has type 0 and then fails `ProposalNotFound`). `_approve` (also run by `_propose` for the proposer, without the type check) checks (`_requirePending`): exists, not executed, not cancelled, not expired; then sender has not approved (`AlreadyApproved`) or rejected (`AlreadyVoted`). Records vote, emits `ProposalApproved`.
3. Re-count valid votes; if ≥ `getThreshold()`: set `executed = true` **before** any external call, dispatch to the handler, emit `ProposalExecuted`.
4. `reject(id)`: same `_requirePending` checks, sender has not voted (`AlreadyVoted`). Records rejection, emits `ProposalRejected`. If valid rejections ≥ `getThreshold()`: `cancelled = true`, emit `ProposalCancelled`.
5. If the handler reverts, the whole approve tx reverts — the vote is not recorded and the proposal stays pending (can be retried later while not expired).
### Security
Invariant #7: expired / executed / cancelled (by proposer or by ≥ 50% rejections) proposals can never execute. Checks-effects-interactions on `executed`.
### Edge cases
- Proposals (incl. `WithdrawBatch`) work while paused.
- Several proposals can be pending at the same time; creating one never affects the others.
- A proposal is executable up to and including `createdAt + 1 days`; one second later it is expired.
- **Stable change expires everything pending**: `ChangeStableToken` sets `stableChangedAt = block.timestamp`; every proposal with `createdAt <= stableChangedAt` is expired (`ProposalExpired` on approve / reject, `expired = true` in `getProposal`). Its payload was vetted against the old stable — e.g. a pending `SetAllowedPool(WETH, 500, 10)` meant for USDC/WETH would otherwise whitelist the unvetted newStable/WETH pool, and a pending `ChangeMorphoVault` would point the new stable at a USDC vault. Proposals created in the same block as the switch are expired too; re-propose in a later block. `cancel` still works on them (housekeeping). See [morpho-integration §5](morpho-integration.md#5-changestabletoken).

## 2. Vote counting, expiry & rejection
- `_countValidApprovals(id)` / `_countValidRejections(id)` loop `signers[]` and count `hasApproved` / `hasRejected`. Only **current** signers count (invariant #6). Removed signers also cannot vote (they fail `onlySigner`).
- **Cancelling someone else's proposal needs ≥ 50% "no" votes**: valid rejections ≥ `getThreshold()` (2→1, 3→2, 4→2, 5→3). One signer alone can never cancel another signer's proposal (except with 2 signers, where 1 is already the threshold for everything) — neither by rejecting nor by creating new proposals.
- The proposer can still withdraw their **own** proposal with `cancel(id)`; this cannot affect anyone else's proposal.
- With 4 signers, 2 approvals execute and 2 rejections cancel — whichever is reached first wins (each signer votes only once).
- Edge cases: a removed-then-re-added signer's old `hasApproved` / `hasRejected` flags count again on proposals that are still pending. Older pending proposals (e.g. an `Unpause` created before an emergency pause) stay usable for 1 day unless they are rejected or cancelled by the proposer.

## 3. Proposal types and payloads
Each handler re-validates against live state at execute time (state may have changed since propose).

| ProposalType | `data` (abi.encode) | Constraints | Handler doc |
|---|---|---|---|
| `WithdrawBatch` | `(address[] tokens, uint256[] amounts, address to)` | `to` whitelisted; tokens whitelisted; equal non-empty arrays; amounts > 0; `type(uint256).max` = all (skipped if empty) | [security-safety §3](security-safety.md#3-withdrawbatch) |
| `AddWithdrawAddress` | `address` | ≠ 0, not already | [roles-multisig §3](roles-multisig.md#3-withdraw-addresses) |
| `RemoveWithdrawAddress` | `address` | must exist | same |
| `AddSigner` | `address` | ≠ 0, not signer, not operator | [roles-multisig §1](roles-multisig.md#1-signers) |
| `RemoveSigner` | `address` | ≥ 2 remain | same |
| `AddOperator` | `address` | ≠ 0, not operator, not signer | [roles-multisig §2](roles-multisig.md#2-operators) |
| `RemoveOperator` | `address` | must exist | same |
| `ChangeMorphoVault` | `address newVault` | ≠ 0, ≠ current (no factory / `asset()` check — signers verify off-chain) | [morpho-integration §4](morpho-integration.md#4-changemorphovault-migration) |
| `AddToken` / `RemoveToken` | `address` | Tradable tokens only; `address(0)` = native ETH is valid; `AddToken(stableToken)` → `StableNotTradable` | [security-safety §2](security-safety.md#2-stable--tradable-tokens--anti-junk-token) |
| `SetAllowedPool` | `(address token, uint24 fee, int24 tickSpacing, bool allowed)` | add: token ≠ stable, `1 <= fee <= 1_000_000`, `0 <= tickSpacing <= 32767` (0 = V3), no V3 entry for native ETH (propose + execute); not already listed (`Duplicate`). remove: must be listed (`NotFound`) | [swap-v3 §3](swap-v3.md#3-pool-whitelist-allowedpool--shared-with-v4) |
| `Unpause` | empty bytes | must be paused at execute | [security-safety §1](security-safety.md#1-pause--unpause) |
| `ChangeUniV3Router` | `address newRouter` | ≠ 0, ≠ current (`SameAddress`, propose + execute); not validated on-chain | [swap-v3 §5](swap-v3.md#5-changing-the-router-changeuniv3router) |
| `ChangePermit2` | `address` | ≠ 0, ≠ current | [swap-v4 §3](swap-v4.md#3-changing-permit2--universalrouter) |
| `ChangeUniversalRouter` | `address` | ≠ 0, ≠ current | same |
| `ChangeStableToken` | `(address newStable, address newVault, address to)` | non-zero; new ≠ current stable / vault; `newStable` not tradable; `to` whitelisted. Sweeps all old stable to `to` first; resets `dailyVolumeCap` to 0 | [morpho-integration §5](morpho-integration.md#5-changestabletoken) |

| `SetDailyVolumeCap` | `uint256 cap` | exactly 32 bytes (`BadArrayLength`); any value, `0` = no swaps | [swap-v3 §6](swap-v3.md#6-daily-volume-cap-dailyvolumecap--shared-with-v4) |

17 types — the number is what signers pass to `approve(id, pType)`: `WithdrawBatch` = 0, `AddWithdrawAddress` = 1, `RemoveWithdrawAddress` = 2, `AddSigner` = 3, `RemoveSigner` = 4, `AddOperator` = 5, `RemoveOperator` = 6, `ChangeMorphoVault` = 7, `AddToken` = 8, `RemoveToken` = 9, `SetAllowedPool` = 10, `Unpause` = 11, `ChangeUniV3Router` = 12, `ChangePermit2` = 13, `ChangeUniversalRouter` = 14, `ChangeStableToken` = 15, `SetDailyVolumeCap` = 16. Off-chain tooling must use these values. `ChangeMorphoVault` and the three `Change*` types reject the current address already at propose time (`SameMorphoVault` / `SameAddress`); execute re-checks (two pending proposals for the same new address → the second reverts). `ChangeStableToken` swaps the stable and its Morpho vault after sweeping all old stable to `to`.

There is **no** proposal that approves arbitrary tokens / spenders.

## 4. Helper `proposeXxx` functions
`proposeWithdrawBatch`, `proposeAddWithdrawAddress`, `proposeRemoveWithdrawAddress`, `proposeAddSigner`, `proposeRemoveSigner`, `proposeAddOperator`, `proposeRemoveOperator`, `proposeChangeMorphoVault`, `proposeAddToken`, `proposeRemoveToken`, `proposeSetAllowedPool`, `proposeUnpause`, `proposeChangeUniV3Router`, `proposeChangePermit2`, `proposeChangeUniversalRouter`, `proposeChangeStableToken`, `proposeSetDailyVolumeCap`.
They ABI-encode the payload and call internal `_propose` — never `this.propose()`, which would make `msg.sender` the vault itself (tested: `proposer` is the calling signer).

## Related
- [roles-multisig.md](roles-multisig.md)
- [security-safety.md](security-safety.md)
- [morpho-integration.md](morpho-integration.md)
