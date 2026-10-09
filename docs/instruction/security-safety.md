# Security & Safety
> Last updated: 2026-10-09

## Overview
How the vault keeps funds safe even if the operator key is stolen.
Sub-logics:
1. Pause / Unpause
2. Stable / tradable tokens & anti-junk-token
3. WithdrawBatch
4. The §10 invariants and their tests
5. Accepted risks
6. EIP-7702 delegated callers blocked

## Shared
- Code: `pause()` + `Unpause` in `src/vault/DCAVaultProposals.sol`; `whenNotPaused` / `onlyOperator` modifiers and all state in `src/vault/DCAVaultStorage.sol`; token whitelist setters in `src/vault/DCAVaultRoles.sol`.
- Storage: `paused`, `stableToken`, `allowedToken`, `_allowedTokenList` (internal mirror for views, no public getter), `_expectingNative` (internal receive() window flag).
- Constant: `NATIVE = address(0)` (native ETH currency id, as in Uniswap V4).
- Events: `Paused(by)`, `Unpaused()`, `TokenAllowed(token, allowed)`, `Withdrawn(token, to, amount)`.
- Errors: `DelegatedCaller`, `IsPaused`, `NotPaused`, `TokenNotAllowed`, `StableNotTradable`, `PairNotAllowed`, `UnexpectedNative`, `NativeTransferFailed`, `WithdrawAddressNotAllowed`, `BadArrayLength`, `InsufficientBalance`.
- `ReentrancyGuard` on every state-changing function that touches an external contract.

## 1. Pause / Unpause
- `pause()` — `onlySigner`, any single signer, immediate. Reverts `IsPaused` if already paused.
- Unpause only via `Unpause` proposal (threshold). Reverts `NotPaused` at execute if not paused.
- While paused: every operator function reverts `IsPaused`. `depositAndSupply` and all proposals (incl. `WithdrawBatch`) still work.
- Why: pausing cannot lose money, so one signer can react instantly to a compromised operator.

## 2. Stable / tradable tokens & anti-junk-token
Two separate lists (owner decision 2026-10-08):
- **`stableToken`**: exactly one address (USDC). It is the only token that can be deposited, the only one supplied to Morpho, and one side of every swap. Changed only via `ChangeStableToken`, which sweeps the old stable out first ([morpho-integration §5](morpho-integration.md#5-changestabletoken)).
- **`allowedToken`**: the tradable tokens (WETH, cbBTC, …), held idle. **Never contains the stable** (`StableNotTradable` in the constructor, `AddToken` and `ChangeStableToken`). It may contain `address(0)` = **native ETH**, which only Uniswap V4 can trade ([swap-v4 §1](swap-v4.md#1-swapexactinputv4)).

Rules:
- Constructor `_tokens[]` = tradable tokens only (must not contain the stable); duplicates revert. `address(0)` is accepted (native ETH).
- `AddToken` / `RemoveToken` proposals manage the tradable list. Any tradable token, including native ETH, can be removed. The stable is not in the list, so `RemoveToken(stable)` fails with `NotFound`. `RemoveToken` also kills every pool whitelist entry of that token for good — re-adding it requires `SetAllowedPool` again ([swap-v3 §3](swap-v3.md#3-pool-whitelist-allowedpool--shared-with-v4)).
- "Is this the stable?" is always an address compare against `stableToken`, never a lookup in `allowedToken`.
- Swaps: one side must be `stableToken` (`PairNotAllowed` otherwise, so no token ↔ token), and the other side must be in `allowedToken` (`TokenNotAllowed`). `WithdrawBatch` accepts the stable or a whitelisted token.
- Junk tokens transferred in are ignored: no loop over held tokens, no `balanceOf` / call on any address other than the stable and whitelisted tokens, no rescue function. A replaced stable becomes junk the same way.
- `getAllowedTokens()` returns the tradable list. `getBalances()` → `(stableIdle, stableInMorpho, tokens[], balances[])`: the stable is reported separately, and native ETH is read as `address(this).balance`.
- **Receiving ETH**: there is no `fallback()`. `receive()` only accepts ETH while `swapExactInputV4` is buying native ETH (`_expectingNative` is set right before `UniversalRouter.execute` and cleared right after, inside the `nonReentrant` swap); otherwise it reverts `UnexpectedNative`. Whitelisting `address(0)` does **not** make the vault accept plain ETH transfers.

## 3. WithdrawBatch
### Entry points
Proposal `WithdrawBatch(address[] tokens, uint256[] amounts, address to)` / `proposeWithdrawBatch`.
### Flow (`_withdrawBatch`)
1. `to` must be in `isWithdrawAddress`; arrays equal length, non-empty.
2. For each token: amount > 0, and the token is the stable or whitelisted.
   - **Stable** (`_prepareStable`): `max` → redeem all Morpho shares, send the whole stable balance. Otherwise, if idle < amount, withdraw the shortfall from Morpho.
   - **Other tokens**: `max` → whole balance; else require amount ≤ balance (`InsufficientBalance`). Native ETH (`address(0)`) balance = `address(this).balance`.
   - **`max` resolving to 0** (token empty at execute time): the token is skipped — no transfer, no `Withdrawn` event. An explicit amount is never skipped.
3. `_sendToken`: ERC20 → `safeTransfer(to, amount)`; native ETH → `to.call{value: amount}("")` (empty calldata, `to` is a whitelisted withdraw address; failure → `NativeTransferFailed`). Emit `Withdrawn`.
### Security
Every token that leaves the contract goes to an address in `isWithdrawAddress` (added only by a signer proposal); everything else fails. The only other outflows are protocol interactions whose output comes back to the vault (router swap — router changeable only at threshold, Morpho deposit) and `ChangeMorphoVault`, which sends all stable to whatever vault a threshold of signers approved — not validated on-chain, so signers must verify it ([morpho-integration §4](morpho-integration.md#4-changemorphovault-migration)).
### Edge cases
Any failure reverts the whole batch. This includes a native-ETH withdrawal to a contract that cannot receive ETH, so pick an EOA / Safe. Duplicate tokens in one batch are processed in order (a second `max` of the same token finds 0 and is skipped). A batch where every `max` token is empty still executes, as a no-op.

### Recover everything to one address
One proposal, no extra function: `proposeWithdrawBatch([stableToken, ...getAllowedTokens()], [max, max, ...], to)` with `to` in `isWithdrawAddress`. On execute it redeems all Morpho shares, then sends every non-empty token to `to`; empty ones are skipped, so balance changes between propose and execute cannot block it. Optionally `pause()` first so the operator stops swapping meanwhile.

## 4. The §10 invariants and their tests
All in `test/DCAVault.security.t.sol`:

| # | Invariant | Test(s) |
|---|---|---|
| 1 | Operator can't move tokens out | `testFuzz_Invariant1_OperatorCannotExtract`, `..._OperatorCannotUseSignerFunctions`, `..._RouterCannotPullMoreThanAmountIn`, `..._LyingRouterIsCaughtByBalanceDelta`, `..._V4RouterCannotPullMoreThanAmountIn`, `..._V4ShortOutputIsCaughtByBalanceDelta` (fuzz covers V3 + V4) |
| 2 | Outputs go to `address(this)` | `test_Invariant2_*` |
| 3 | Allowances 0 after each tx (router, Morpho, ERC20 → Permit2, Permit2 → UniversalRouter) | `test_Invariant3_AllowancesZeroAfterEveryFlow`, `test_Invariant3_V4Permit2AllowanceExpiresThisBlock` (+ fork `_assertNoAllowances` / `_assertNoPermit2Allowances`) |
| 4 | Withdraw only via approved batch to whitelist | `test_Invariant4_*` (incl. non-whitelisted `to`, non-allowed token, token removed before execute) |
| 5 | Signers ≥ 2 | `test_Invariant5_*` (incl. concurrent removals) |
| 6 | Removed signer's votes don't count | `test_Invariant6_*`, `test_Reject_RemovedSignerRejectionNotCounted` |
| 7 | Expired/executed/cancelled never execute | `test_Invariant7_*` |
| 8 | Pause blocks operator; unpause by proposal | `test_Invariant8_*` |
| 9 | No delegatecall/selfdestruct/callcode | `test_Invariant9_NoDelegatecallOrSelfdestruct` (bytecode opcode scan) |
| 10 | Rejects ETH (except native-ETH V4 buy output) | `test_Invariant10_RejectsEth`, `test_Invariant10_RejectsEthWhenNativeWhitelisted`, `test_Invariant10_RouterCannotPushEthDuringErc20Swap` |
| 11 | Only the stable in; whitelist enforced | `test_Invariant11_*` |
| 12 | Junk tokens harmless | `test_Invariant12_JunkTokenDoesNotAffectAnyFlow` |
| — | Reentrancy | `test_Security_ReentrancyBlocked` |
| — | One signer cannot cancel others' proposals | `test_Security_SingleSignerCannotCancelOthers` |
| — | Swap needs a stable side | `testFuzz_Security_SwapNeedsUsdcSide` |
| — | Only listed (token, fee, tickSpacing) pools are reachable | `testFuzz_Security_UnlistedPoolAlwaysRejected`, `test_Fork_Revert_SwapExactInputV4_UnlistedPoolCombo` |
| — | Protocol addresses change only at threshold | `test_Security_ChangeProtocolAddressesNeedThreshold`, `test_Security_ChangeMorphoVaultNeedsThreshold` |
| — | Old router keeps no allowance after a switch | `test_Security_OldRouterHasNoPowerAfterChange` |
| 13 | 7702-delegated callers blocked everywhere | `test_Security_DelegatedOperatorBlocked`, `test_Security_DelegatedSignerBlocked`, `test_Security_DelegatedDepositorBlocked`, `test_Security_ContractCallerNotTreatedAsDelegated` |
| — | Every signer function checks the role (incl. `reject`, `cancel`, `pause`) | `test_Invariant1_OperatorCannotUseSignerFunctions`, `test_Revert_Cancel_ProposerNoLongerSigner` |

## 5. Accepted risks
Found in the 2026-10-08 security review; the owner chose to keep the spec behavior. Full list: `DCA_VAULT_SPEC.md` §16.
1. **Operator sandwich.** The contract only checks `amountOutMinimum > 0`. A stolen operator key can move the price of a **listed** pool, then call `swapExactInputV3` / `swapExactInputV4(stable → token, all stable, minOut = 1)` (or sell all WETH / cbBTC) and back-run — tokens never leave directly, but much of the value can. This needs real capital against a deep pool **only because 7702-delegated callers are blocked** ([§6](#6-eip-7702-delegated-callers-blocked)): without that, flash loan + price push + vault swap + back-run fit in one tx with zero capital, whatever the pool TVL. The cheaper variant — routing into an unlisted, attacker-created pool — is blocked by the per-pool whitelist ([swap-v3 §3](swap-v3.md#3-pool-whitelist-allowedpool--shared-with-v4)), provided signers only list pools that exist with liquidity. Mitigation today: any signer `pause()`s on the first suspicious `Swapped` event; keep few operators; monitor.
2. **`ChangeMorphoVault` is all-or-nothing.** A paused / illiquid / broken old vault makes the full `redeem` revert, so the vault cannot be switched; deposits and sell proceeds keep flowing into it. Mitigation: `pause()` to stop sells.
3. **2 signers ⇒ threshold 1.** One leaked signer key alone can whitelist an address and withdraw everything, add signers, or switch the router. Deploy with ≥ 3 signers.
4. **Stale `Unpause` proposals** from an earlier pause stay approvable for 7 days. Cancel / reject leftovers.
5. **Protocol addresses are not validated on-chain** (Morpho vault, router, Permit2, UniversalRouter): a threshold proposal can set any address. Same trust as `AddWithdrawAddress` + `WithdrawBatch`.

## 6. EIP-7702 delegated callers blocked
### Purpose
With EIP-7702 (live on Base) an EOA can attach contract code to itself. A leaked operator key could then run attack code **as** the operator (`msg.sender == operator`) and do, in one atomic tx: flash loan → push the price of a listed pool → `swapExactInput*(all stable / all token, minOut = 1)` → back-run → repay. No capital is needed and no signer can `pause()` in between. Blocking delegated callers forces every step into its own tx, so a manipulation needs real capital and risks being arbitraged.
### Entry points
`_checkNotDelegated()` in `src/vault/DCAVaultStorage.sol`, run by:
- `onlySigner` — `pause`, `propose`, every `proposeXxx`, `approve`, `reject`, `cancel`
- `onlyOperator` — `swapExactInputV3`, `swapExactInputV4`, `morphoDeposit`
- `notDelegated` — `depositAndSupply`

Views and `receive()` are not checked (`receive()`'s sender is the V4 PoolManager).
### Flow
1. If `msg.sender` has code, copy its first byte (`extcodecopy`).
2. First byte `0xef` ⇒ it is the 7702 designator `0xef0100 || implementation` ⇒ revert `DelegatedCaller`.
3. The check runs before the role check, so a delegated caller gets `DelegatedCaller` even if it is not a signer / operator.
### Security
EIP-3541 forbids deploying code that starts with `0xEF`, so a leading `0xef` is always a delegation — ordinary contracts (e.g. a Safe used as signer or depositor) keep working.
### Edge cases
- A signer / operator / depositor that delegated (e.g. accepted a wallet "smart account" upgrade) is locked out until it clears the delegation (delegate to `address(0)`); funds are not affected.
- Well-known test keys are often delegated to sweeper contracts on mainnet: on Base `makeAddr("user")` / `makeAddr("treasury")` carry a 7702 designator, so the fork test uses `makeAddr("dcaForkDepositor")` as depositor. Never use such addresses as real roles.

## Related
- [proposal-system.md](proposal-system.md)
- [roles-multisig.md](roles-multisig.md)
- [swap-v3.md](swap-v3.md)
