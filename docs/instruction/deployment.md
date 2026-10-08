# Deployment
> Last updated: 2026-10-08

## Overview
Constructor arguments, the deploy script, address verification and the post-deploy checklist.
Sub-logics:
1. Constructor
2. Deploy script
3. Verified Base addresses
4. Post-deploy checklist
5. Source layout

## 1. Constructor
`DCAVault(stableToken, uniV3Router, permit2, universalRouter, morphoVault, signers[], operators[], withdrawAddresses[], tokens[], pools[])`
Validates: stable and all protocol addresses non-zero (`morphoVault` is **not** checked further on-chain — the deploy script pre-flights `asset() == stableToken`); signers ≥ 2, non-zero, unique; operators non-zero, unique, not signers; withdraw addresses non-zero, unique; `tokens[]` = **tradable tokens only**: unique, must **not** contain the stable (`StableNotTradable`), may contain `address(0)` (native ETH, V4 only); `pools[]` = `PoolConfig{token, fee, tickSpacing}` entries, unique, validated as in [swap-v3 §3](swap-v3.md#3-pool-whitelist-allowedpool--shared-with-v4) (tickSpacing 0 = V3 pool, ≥ 1 = hookless V4 pool).
No protocol address is hardcoded in the contract.

## 2. Deploy script
`script/Deploy.s.sol` reads everything from env (template: `.env.example`):
`STABLE_TOKEN, TOKENS, UNI_V3_ROUTER, PERMIT2, UNIVERSAL_ROUTER, MORPHO_VAULT, SIGNERS, OPERATORS, WITHDRAW_ADDRESSES, UNI_V3_FACTORY, POOL_TOKENS, POOL_FEES, POOL_TICK_SPACINGS, PRIVATE_KEY_DEPLOYER`.
`STABLE_TOKEN` = USDC. `TOKENS` = tradable tokens (default `WETH,cbBTC`); append `0x0000000000000000000000000000000000000000` to also whitelist native ETH.
Pool whitelist = three parallel lists, entry i = (`POOL_TOKENS[i]`, `POOL_FEES[i]`, `POOL_TICK_SPACINGS[i]`), tick spacing 0 = V3. Default: V3 USDC/WETH 500, V3 USDC/cbBTC 500, V4 USDC/WETH 500/10 and 3000/60, V4 USDC/cbBTC 500/10. Only list pools that exist with liquidity.
Lists are comma-separated without spaces. `OPERATORS` may be empty; `WITHDRAW_ADDRESSES` must not be.
Contract runtime size: 23,942 B (634 B under the EIP-170 limit of 24,576 B) — any new logic must be size-checked (`forge build --sizes`).
Pre-flight: requires chainId 8453, code at every address (except `address(0)` in `TOKENS`), `STABLE_TOKEN` not in `TOKENS`, Morpho asset == `STABLE_TOKEN`, `POOL_*` lists of equal length, every V3 pool entry exists (`UNI_V3_FACTORY.getPool(stable, token, fee) != 0`); prints the full config. V4 pool entries are not checked by the script — verify them on a fork first.
```bash
cp .env.example .env   # fill in, never commit
source .env
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL            # dry run, read the log
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

## 3. Verified Base addresses (on-chain check 2026-10-08, block ~52.3M)
| Name | Address | Check |
|---|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | symbol USDC, 6 dec |
| WETH | `0x4200000000000000000000000000000000000006` | symbol WETH, 18 dec |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | symbol cbBTC, 8 dec |
| SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | code ✓, swaps pass on fork |
| QuoterV2 | `0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a` | quotes work on fork |
| V3 Factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` | pools found |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | code ✓ |
| UniversalRouter | `0x6ff5693b99212da76ad316178a184ab56d299b43` | code ✓; V4 swaps through it verified on a Base fork 2026-10-08 (fork tests) |
| Steakhouse High Yield USDC (bbqUSDC) | `0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100` | `asset()` = USDC, TVL ≈ 25M; Morpho **Vault V2** |

The checks above were done via RPC; still cross-check on basescan.org before mainnet broadcast.

## 4. Post-deploy checklist
Spec §13: verify on basescan → check `getSigners()`, operators, withdraw addresses, `stableToken`, tradable tokens (`getAllowedTokens()`), fees, `morphoVault` → fund operator with ~0.01–0.02 ETH → small `depositAndSupply` → small buy (e.g. 5 USDC → WETH) → `pause()` + `Unpause` proposal → small `WithdrawBatch` → revoke the old EOA unlimited approvals → start the bot.

**A third-party audit is required before significant funds.** Start with small amounts.

## 5. Source layout
### Purpose
`DCAVault` is split into abstract modules for readability. They are all compiled into **one** immutable contract (single deployment, no proxy, no delegatecall).
### Files
| File | Contents |
|---|---|
| `src/DCAVault.sol` | Final contract: constructor seeds signers / operators / withdraw addresses / tokens / pools (`PoolConfig[]`). |
| `src/vault/DCAVaultStorage.sol` | Types, constants (incl. `NATIVE = address(0)`), **all** state (incl. `stableToken`, `morphoVault`, `uniV3Router`, `permit2`, `universalRouter`, changeable only by proposal), events, errors, modifiers; base constructor sets stable + protocol addresses (non-zero check only). |
| `src/vault/DCAVaultRoles.sol` | Role / whitelist setters, `getSigners`, `getAllowedTokens`, `allowedPool`, `getThreshold`. |
| `src/vault/DCAVaultMorpho.sol` | Morpho deposit / withdraw / migration, `ChangeStableToken`, `totalStable`, `getBalances`, native-aware `_balanceOf` / `_sendToken`. |
| `src/vault/DCAVaultSwap.sol` | Base of the swap modules: `_prepareSwap` (shared rules + Morpho pull on a buy) + `_settleSwap` (balance-delta output, `Swapped`, sell → Morpho). |
| `src/vault/DCAVaultSwapV3.sol` | V3 swaps via SwapRouter02: `swapExactInputV3` (buy and sell). |
| `src/vault/DCAVaultSwapV4.sol` | V4 swap via UniversalRouter + Permit2: `swapExactInputV4` (incl. native ETH), guarded `receive()`. |
| `src/vault/DCAVaultProposals.sol` | `pause`, proposal lifecycle, execution dispatch, `WithdrawBatch`. |

Inheritance: `Storage ← Roles ← Morpho ← {Swap ← {SwapV3, SwapV4}, Proposals} ← DCAVault`.
### Edge cases
- All state is declared only in `DCAVaultStorage`, so the storage layout is fixed in one place (identical to the pre-split single file).
- Custom errors, events and `ProposalType` are declared in `DCAVaultStorage`; off-chain code / tests reference them as `DCAVaultStorage.X` (Solidity does not expose inherited errors as `DCAVault.X`). Selectors and ABI encoding are unchanged; only the ABI `internalType` label reads `DCAVaultStorage.ProposalType`.

## Related
- [roles-multisig.md](roles-multisig.md)
- [security-safety.md](security-safety.md)
