# Morpho Integration
- **Date**: 2026-10-15
- **Feature**: morpho-integration (→ docs/instruction/morpho-integration.md)
- **Type**: Changed
- **Files**: `src/vault/DCAVaultMorpho.sol`, `test/DCAVault.t.sol`
- **What**:
  - **ChangeStableToken**: now also sets `dailyVolumeCap` and `dailyVolumeUsed` to 0 (emits `DailyVolumeCapChanged(old, 0)`), so swaps stay blocked until signers pass a `SetDailyVolumeCap` in new-stable units.
- **Tests**: added `test_ChangeStableToken_ResetsDailyVolumeCap`. `forge test`: 235 passed, 0 failed.
- **Why**:
  - The cap and usage are raw old-stable units; with a stable of different decimals (e.g. 6 → 18 or 18 → 6) they would mean a wildly different dollar amount. Resetting to 0 is fail-safe, like the pool whitelist that is dropped on the same switch.
