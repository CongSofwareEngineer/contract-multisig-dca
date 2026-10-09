# CLAUDE.md — contract-multisig-dca (DCA Vault, Base)

## 0. Source of truth

[DCA_VAULT_SPEC.md](DCA_VAULT_SPEC.md) is the **design spec and the source of truth**.
Read it fully before writing any code.

- Every point marked `⚠️ CẦN XÁC NHẬN` in the spec must be **asked to the project owner
  before implementing** that part. Do not guess.
- Do **NOT** add features outside the spec. In particular: never add a function that
  lets the operator call an arbitrary address with arbitrary calldata.
- If reality contradicts the spec (e.g. an address is wrong on basescan, a pool has no
  liquidity), stop, report it, and ask — do not silently deviate.
- When a decision changes the design, update `DCA_VAULT_SPEC.md` too, not just the code.

## 1. Project Overview

A single immutable Solidity vault on **Base mainnet** (chainId `8453`) that DCAs into
**cbBTC** and **WETH** over ~3 years:

- **One stablecoin** (`stableToken`, USDC) is kept separate from the tradable-token list
  (`allowedToken`: WETH, cbBTC, optionally native ETH = `address(0)` for V4).
- Idle **stable always sits in a MetaMorpho Vault** (ERC-4626) earning yield; only the stable
  goes to Morpho.
- An **off-chain bot** decides when to buy/sell and submits txs with the `operator` key;
  the vault withdraws exactly the USDC needed from Morpho → swaps on Uniswap V3.
- Bought cbBTC / WETH **stay in the contract**. Nothing is forwarded anywhere.
- Tokens can only leave via a **multisig-approved `WithdrawBatch`**, and only to a
  whitelisted address — so a compromised operator key cannot drain funds.

This replaces an EOA setup that held unlimited approvals to Uniswap V3 Router, Permit2
and the Morpho Bundler.

**Out of scope here:** the off-chain bot service (DCA conditions, `amountOutMinimum` via
QuoterV2, signing with the operator key). It gets its own spec.

## 2. Tech Stack

- **Solidity** `^0.8.24`
- **Foundry** (forge, cast, anvil) — no Hardhat
- **OpenZeppelin Contracts v5** — `SafeERC20`, `ReentrancyGuard`, `IERC4626`
- **No proxy, no upgradeable pattern.** Contract is immutable; config changes go through
  multisig proposals only.
- Tests run against a **Base mainnet fork** (`anvil --fork-url` / `forge test --fork-url`)

## 3. Project Structure

```
.
├── foundry.toml
├── .env.example             # BASE_RPC_URL, PRIVATE_KEY_DEPLOYER, BASESCAN_API_KEY
├── DCA_VAULT_SPEC.md        # design spec — source of truth
├── src/
│   ├── DCAVault.sol             # final contract + constructor (inherits the modules below)
│   ├── vault/
│   │   ├── DCAVaultStorage.sol  # types, constants, state, events, errors, modifiers (no immutables)
│   │   ├── DCAVaultRoles.sol    # signers / operators / withdraw addresses / token & pool whitelists
│   │   ├── DCAVaultMorpho.sol   # depositAndSupply, morphoDeposit, ChangeMorphoVault migration
│   │   ├── DCAVaultSwap.sol     # shared swap checks + settlement (base of V3 / V4)
│   │   ├── DCAVaultSwapV3.sol   # swapExactInputV3 (buy = Morpho withdraw + swap)
│   │   ├── DCAVaultSwapV4.sol   # swapExactInputV4 (UniversalRouter + Permit2)
│   │   └── DCAVaultProposals.sol # pause, propose/approve/cancel, execute, WithdrawBatch
│   └── interfaces/
│       ├── ISwapRouter02.sol
│       ├── IPermit2.sol
│       ├── IUniversalRouter.sol
│       └── IV4Router.sol        # PoolKey / ExactInputSingleParams for the V4_SWAP command
├── test/
│   ├── DCAVault.t.sol           # unit: roles, proposals, threshold, limits
│   ├── DCAVault.fork.t.sol      # fork Base: deposit → Morpho, buy (Morpho → swap),
│   │                            #   sell → Morpho, batch withdraw, change vault
│   ├── DCAVault.security.t.sol  # the §10 invariants + malicious-operator tests
│   ├── helpers/
│   │   └── VaultTestBase.sol    # shared setUp: mocks, roles, token & pool whitelists
│   └── mocks/                   # MockERC20, MockMorphoVault, MockSwapRouter, MockPermit2,
│                                #   MockUniversalRouter, ReentrantMorphoVault, JunkToken
├── docs/
│   ├── instruction/             # one file per main feature — current behavior (§10.3)
│   └── changelog/               # YYYY-MM-DD_<feature-name>.md (§10.2)
└── script/
    └── Deploy.s.sol             # reads addresses from env/config, deploys, verifies
```

## 4. Roles (on-chain)

| Role | Who | Can do |
|---|---|---|
| `signer` (≥ 2) | Hardware / cold wallets of the owner | Everything, via proposal + vote. Plus `pause()` alone. |
| `operator` (≥ 0) | Hot wallet held by the bot service | **Only** swaps + `morphoDeposit`. No Morpho withdraw (a buy pulls from Morpho itself). Pays its own gas. |
| anyone | — | `depositAndSupply` (USDC in) only |

- A single address must **never** be both signer and operator (enforced in constructor
  and in `AddSigner` / `AddOperator`).
- There is **no `bot` role** on-chain — the bot is just an operator key.
- The contract never pays gas; the caller does.

## 5. Security Rules (non-negotiable)

These are the §10 invariants of the spec. Every one needs a test in
`test/DCAVault.security.t.sol`.

1. The operator **cannot** make tokens leave the contract, except `tokenIn` into the
   router during a swap and USDC into the Morpho vault.
2. Swap output and Morpho withdrawals **always** go to `address(this)` — `recipient` /
   `receiver` / `owner` are hardcoded, never taken from a parameter.
3. After every tx, the contract's allowance to router / Permit2 / Morpho is **0**
   (approve exact amount → use → `forceApprove(..., 0)` in the same call).
4. Tokens leave only via a fully-approved `WithdrawBatch`, and only to an address in
   `isWithdrawAddress`.
5. `signers.length` is **never < `MIN_SIGNERS = 2`**.
6. Votes from an address that is no longer a signer **do not count** — re-count valid
   votes at execute time.
7. An expired (> 7 days, or created at/before the last `ChangeStableToken`), executed or cancelled proposal
   can never execute.
8. While `paused`, every operator function reverts. One signer can pause immediately;
   unpausing requires a threshold `Unpause` proposal.
9. No `delegatecall`, no `selfdestruct`, no calling an arbitrary address with arbitrary
   calldata.
10. The contract **rejects ETH** — no payable `fallback()`; `receive()` only accepts ETH while
    `swapExactInputV4` is buying native ETH (`_expectingNative` flag), and reverts otherwise.
11. Only the stable can be deposited, via `depositAndSupply` (no generic
    `deposit(address token, ...)`). Swap / withdraw revert for any token that is not
    `stableToken` and not in `allowedToken`. "Is it the stable?" is always an address compare
    against `stableToken` — the stable is never in `allowedToken`.
12. Junk tokens transferred directly in **must not** make any function revert or change
    behavior: never loop over "all tokens held", never read the balance of a non-
    whitelisted token, never call into a non-whitelisted token address. There is **no
    rescue function** — junk sits there, harmless.
13. An EIP-7702 delegated EOA (code starts with `0xef`) **cannot call any state-changing
    function** (`DelegatedCaller`) — it would let a leaked operator key bundle flash loan +
    pool manipulation + vault swap into one tx. Plain contracts (e.g. a Safe) are unaffected.

Also:
- There is **no "approve arbitrary token/spender" proposal.** Standing approvals must not
  exist anywhere in the design.
- Never hardcode addresses inside the contract — pass them through the constructor.
- Never commit a private key, mnemonic, RPC key or Basescan key. `.env` stays untracked;
  only `.env.example` is committed.

## 6. Implementation Gotchas

- **SwapRouter02 on Base has NO `deadline` field** in `ExactInputSingleParams` (unlike
  SwapRouter V1 on Ethereum):
  ```solidity
  struct ExactInputSingleParams {
      address tokenIn;
      address tokenOut;
      uint24 fee;
      address recipient;
      uint256 amountIn;
      uint256 amountOutMinimum;
      uint160 sqrtPriceLimitX96;
  }
  ```
  The vault checks the deadline itself: `require(block.timestamp <= deadline)`.
- **Helper proposal functions must call the internal `_propose(...)`**, never
  `this.propose(...)` — an external self-call makes `msg.sender` the contract itself.
- **Threshold** = `(signerCount + 1) / 2` (≥ 50%, rounded up), in its own
  `getThreshold()` function. No extra logic. 2→1, 3→2, 4→2, 5→3.
- **Operator safety limits = the pool whitelist `allowedPool` only.** One entry = one pool
  `(token, fee, tickSpacing)` vs the stable; `tickSpacing = 0` = V3 pool, `>= 1` = hookless
  V4 pool. Never split it back into independent fee / tick-spacing lists (the operator could
  combine them into an attacker-created pool). Entries are keyed by epochs
  (`keccak256(stableEpoch, token, _tokenEpoch[token], fee, tickSpacing)`), so `ChangeStableToken` drops them all
  (even when switching back to an old stable) and `RemoveToken` drops that token's for good.
  No per-tx or per-day caps, no TWAP check.
  Slippage is the bot's job via `amountOutMinimum` (contract only checks `> 0`).
- **Contract size is ~456 B under the EIP-170 limit** (24,576 B). Run `forge build --sizes`
  after any change; deploy fails on mainnet if it goes over.
- **Pool whitelist in practice** (one side is always the stable; checked on a Base fork
  2026-10-08): V3 USDC/WETH `500`, V3 USDC/cbBTC `500`, V4 USDC/WETH `500/10` and
  `3000/60`, V4 USDC/cbBTC `500/10`. A WETH/cbBTC pool can never be used — one side must
  be `stableToken` (`PairNotAllowed`).
- Decimals differ — USDC 6, cbBTC 8, WETH 18. Never assume 18.
- **Verify every Base address on basescan.org** before putting it in the deploy script.
  Addresses are listed in [DCA_VAULT_SPEC.md §3](DCA_VAULT_SPEC.md).
- V4 (`swapExactInputV4` via UniversalRouter + Permit2) is **implemented** (2026-10-08 —
  no longer a stub). The contract **builds commands/inputs itself** — it never accepts raw
  calldata from the operator — and `hooks` in `PoolKey` is hardcoded to `address(0)`.

## 7. Build & Test Commands

```bash
forge build                                  # compile
forge test                                   # unit tests
forge test --fork-url $BASE_RPC_URL -vvv     # fork tests against Base mainnet
forge test --match-path test/DCAVault.security.t.sol -vvv
forge fmt                                    # format
forge snapshot                               # gas snapshot
anvil --fork-url $BASE_RPC_URL               # local Base fork
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

**After each Phase 1 step: run `forge build` + `forge test` before moving on.**
Do not stack several unverified steps.

## 8. Code Style

- Solidity style guide + `forge fmt` (4-space indent, 120-col lines).
- Order inside a contract: type declarations → immutables → state → events → errors →
  modifiers → constructor → external → public → internal → private → view/pure.
- Prefer **custom errors** over revert strings.
- Checks-Effects-Interactions, plus `nonReentrant` on every state-changing external
  function that touches an external protocol.
- `SafeERC20` for all token calls; `forceApprove` for approvals (never bare `approve`).
- **NatSpec** (`@notice` / `@param`) on every external and public function.
- Comments in Vietnamese or short English — explain **why**, especially around anything
  security-relevant.
- Naming: contracts/interfaces/structs/enums `PascalCase` (interfaces prefixed `I`),
  functions/variables `camelCase`, internal/private prefixed `_`, constants and
  immutables `UPPER_SNAKE_CASE` for true constants, events `PascalCase`.
- Test naming: `test_<Function>_<Behavior>`, `test_Revert_<Function>_<Reason>`,
  `testFuzz_<Function>`.

## 9. Implementation Order

**Phase 1:**
1. Foundry setup + OpenZeppelin
2. Roles + proposal system + `getThreshold()`
3. `depositAndSupply`, `morphoDeposit` (`morphoWithdraw` removed 2026-10-08)
4. `swapExactInputV3` (buy pulls exact USDC from Morpho; sell auto-deposits USDC to Morpho)
5. `WithdrawBatch`, `ChangeMorphoVault` (with migration)
6. Pool whitelist (`allowedPool`), `pause()` (single signer) + `Unpause` proposal
7. Full test suite (unit + fork + security)
8. Deploy script

**Phase 2 (done 2026-10-08):** `swapExactInputV4` via UniversalRouter + Permit2,
incl. native ETH.

Post-deploy operational checklist: [DCA_VAULT_SPEC.md §13](DCA_VAULT_SPEC.md).

## 10. Docs Workflow (MANDATORY — every task)

Docs are grouped by **main feature**, not by small logic.

### Features of this project
`docs/instruction/` holds **one file per main feature**; every sub-logic is a *section
inside* that file. Expected set (~6 files):

| `<feature-name>` | Covers |
|---|---|
| `roles-multisig` | signers, operators, withdraw addresses, threshold |
| `proposal-system` | propose / approve / execute / cancel, expiry, each ProposalType |
| `morpho-integration` | `depositAndSupply`, `morphoDeposit` (no public Morpho withdraw), `ChangeMorphoVault` / `ChangeStableToken` migration |
| `swap-v3` | `swapExactInputV3` (buy = Morpho withdraw + swap), pool whitelist `allowedPool` (shared with V4), atomic approvals |
| `swap-v4` | `swapExactInputV4` via UniversalRouter + Permit2, native ETH, guarded `receive()` |
| `security-safety` | `pause`/`Unpause`, token whitelist, anti-junk-token, the §10 invariants |
| `deployment` | constructor args, deploy script, verification, post-deploy checklist |

- Same feature → same `<feature-name>` (kebab-case) in both `docs/instruction/` and
  `docs/changelog/`.
- Before creating a new file, check whether the logic belongs to an **existing** feature
  file — if so, add/edit a section there. New file only for a genuinely new main feature.
- A sub-logic shared by two features lives in the one it is mainly about; the other file
  links to that section.
- If small per-logic files exist for the same feature, merge them and delete the rest.

### 10.1 Before starting ANY request
- **Read `DCA_VAULT_SPEC.md` and `docs/instruction/` first.** List the folder and read the
  feature file(s) related to what you are about to touch.
- The spec outranks the instruction docs; the instruction docs outrank your memory.
- If no doc exists for the logic yet, say so and add it when you finish (§10.3).

### 10.2 After changing (or adding) ANY logic → changelog (ONE file per feature per day)
- Folder: `docs/changelog/`, file name `YYYY-MM-DD_<feature-name>.md`
  (e.g. `2026-10-08_proposal-system.md`). `<feature-name>` must match the instruction file.
- **One feature + one day = exactly ONE file.** If today's file for that feature exists,
  **update it** — never create a second one, never add `-2` / `-3` suffixes. A different
  day → a new file. **Never edit previous days' files** (that is history).
- **Auto-merge duplicates**: if several files exist for the same date + feature (suffixed,
  or old per-sub-logic files), merge them into `YYYY-MM-DD_<feature-name>.md` and delete
  the others. Check this every time you touch the changelog.
- Write the **day's net result**, not a log of attempts: if a later edit replaced an
  earlier one the same day, describe only the final behavior. Group bullets by sub-logic.
- Content:
  ```md
  # <Feature name>
  - **Date**: YYYY-MM-DD
  - **Feature**: <feature-name> (→ docs/instruction/<feature-name>.md)
  - **Type**: Added | Changed | Fixed | Removed   (several allowed, e.g. "Changed, Fixed")
  - **Files**: `src/...`, `test/...`   (union of all files touched that day)
  - **What**:
    - **<Sub-logic A>**: change (behavior, not a line-by-line diff)
    - **<Sub-logic B>**: change …
  - **Tests**: which tests were added/updated, and `forge test` result
  - **Why**:
    - reason / ticket / bug for each change
  ```
- Use the real current date. Do this automatically — don't wait to be asked.

### 10.3 After changing (or adding) ANY logic → update the instruction doc
- Folder: `docs/instruction/`, file name `docs/instruction/<feature-name>.md` (same name
  as the changelog).
- **One file = one main feature**, one section per sub-logic, written so a teammate who
  has never seen the code understands the whole feature from that one file. Edit the
  existing section; add one if missing.
- Describe **current** behavior only (history lives in the changelog). Structure:
  ```md
  # <Feature name>
  > Last updated: YYYY-MM-DD

  ## Overview        — what it does, why it exists, list of sub-logics
  ## Shared          — state/storage it owns, modifiers, events, errors
  ## 1. <Sub-logic A>
  ### Purpose        — what this part does
  ### Entry points   — functions, who can call them (role), modifiers
  ### Flow           — step by step (input → external calls → state → events)
  ### Security       — which §10 invariant it upholds and how
  ### Edge cases     — reverts, expiry, paused, decimals, migration
  ## 2. <Sub-logic B>
  ...
  ## Related         — links to other docs/instruction/*.md
  ```
- Link with section anchors ("see §3 WithdrawBatch") instead of many small files.

### Notes
- "Logic" = contract behavior, roles, proposals, external protocol calls, events, errors,
  deploy/config. Comment-only or formatting-only changes need no docs.
- Never put private keys, mnemonics, RPC URLs or API keys in docs.
- Docs are written in English (Vietnamese is fine for extra explanation).

## 11. Do Not

- Do NOT implement anything marked `⚠️ CẦN XÁC NHẬN` without asking the owner first.
- Do NOT add features, functions or roles beyond the spec.
- Do NOT give the operator a way to call an arbitrary address / arbitrary calldata.
- Do NOT add a proposal type that approves arbitrary tokens or spenders.
- Do NOT leave any standing approval — approve exact → use → reset to 0, same tx.
- Do NOT take `recipient` / `receiver` / `owner` from a parameter; hardcode `address(this)`.
- Do NOT add payable `fallback()`, widen `receive()` beyond the V4 native-ETH-buy window, or add a
  rescue function for junk tokens.
- Do NOT make the contract upgradeable or add a proxy.
- Do NOT use `delegatecall` or `selfdestruct`.
- Do NOT hardcode protocol addresses in the contract — constructor only.
- Do NOT add dependencies beyond Foundry + OpenZeppelin v5 without discussion.
- Do NOT commit `.env`, keys or broadcast artifacts containing secrets.
- Do NOT weaken or skip a test to make a build pass — report the failure instead.
- Do NOT deploy to mainnet with significant funds: this contract needs a **third-party
  audit** first, and should start with small amounts.
