// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DCAVaultStorage} from "./vault/DCAVaultStorage.sol";
import {DCAVaultSwapV3} from "./vault/DCAVaultSwapV3.sol";
import {DCAVaultSwapV4} from "./vault/DCAVaultSwapV4.sol";
import {DCAVaultProposals} from "./vault/DCAVaultProposals.sol";

/// @title DCAVault
/// @notice Immutable multisig-governed vault on Base that DCAs one stablecoin (USDC) into tradable tokens
///         (cbBTC / WETH / native ETH). Idle stable always sits in a MetaMorpho (ERC-4626) vault; bought tokens
///         stay idle in the contract. An off-chain bot, holding an `operator` key, can only swap stable <->
///         whitelisted tokens and move the stable in/out of Morpho.
///         Tokens leave the contract only through a threshold-approved `WithdrawBatch` proposal,
///         and only to a whitelisted withdraw address.
/// @dev Security model (see DCA_VAULT_SPEC.md section 10):
///      - no standing approvals: approve exact -> use -> reset to 0 in the same call
///      - swap / Morpho output always goes to address(this), never to a parameter
///      - no delegatecall, no selfdestruct, no arbitrary call, no fallback(); receive() only accepts ETH
///        during a V4 swap whose output is native ETH
///      - never touches a token other than `stableToken` / `allowedToken` (junk tokens are ignored, no rescue)
///      Code is split into modules (all compiled into this one immutable contract — no proxy):
///      - DCAVaultStorage   : types, constants, immutables, state, events, errors, modifiers
///      - DCAVaultRoles     : signers / operators / withdraw addresses / token & pool whitelists
///      - DCAVaultMorpho    : depositAndSupply, morphoDeposit / morphoWithdraw, vault migration
///      - DCAVaultSwap      : checks + settlement shared by V3 and V4 swaps
///      - DCAVaultSwapV3    : swapExactInputV3, withdrawAndSwapV3 (SwapRouter02)
///      - DCAVaultSwapV4    : swapExactInputV4 (UniversalRouter + Permit2)
///      - DCAVaultProposals : pause, propose / approve / cancel, proposal execution
contract DCAVault is DCAVaultSwapV3, DCAVaultSwapV4, DCAVaultProposals {
    /// @param _stableToken the single stablecoin (e.g. USDC); must NOT appear in `_tokens`
    /// @param _uniV3Router Uniswap V3 SwapRouter02
    /// @param _permit2 Permit2 (V4 swaps)
    /// @param _universalRouter Uniswap UniversalRouter (V4 swaps)
    /// @param _morphoVault Morpho vault (ERC-4626) for `_stableToken`, chosen by the owner; not validated on-chain
    /// @param _signers initial signers, at least `MIN_SIGNERS`
    /// @param _operators initial operators (may be empty), disjoint from `_signers`
    /// @param _withdrawAddresses initial withdraw whitelist
    /// @param _tokens initial tradable-token whitelist (e.g. WETH, cbBTC; address(0) = native ETH for V4)
    /// @param _pools initial pool whitelist, one (token, fee, tickSpacing) entry per pool;
    ///        tickSpacing `V3_POOL` (0) = V3 pool, >= 1 = hookless V4 pool (e.g. (WETH, 500, 0), (WETH, 500, 10))
    constructor(
        address _stableToken,
        address _uniV3Router,
        address _permit2,
        address _universalRouter,
        address _morphoVault,
        address[] memory _signers,
        address[] memory _operators,
        address[] memory _withdrawAddresses,
        address[] memory _tokens,
        PoolConfig[] memory _pools
    ) DCAVaultStorage(_stableToken, _uniV3Router, _permit2, _universalRouter, _morphoVault) {
        if (_signers.length < MIN_SIGNERS) revert TooFewSigners();

        // Signers first so the operator loop can enforce signer ∩ operator = ∅.
        for (uint256 i; i < _signers.length; ++i) {
            _addSigner(_signers[i]);
        }
        for (uint256 i; i < _operators.length; ++i) {
            _addOperator(_operators[i]);
        }
        for (uint256 i; i < _withdrawAddresses.length; ++i) {
            _addWithdrawAddress(_withdrawAddresses[i]);
        }
        for (uint256 i; i < _tokens.length; ++i) {
            _addToken(_tokens[i]); // reverts if a token is the stable (lists stay disjoint)
        }
        for (uint256 i; i < _pools.length; ++i) {
            _setAllowedPool(_pools[i].token, _pools[i].fee, _pools[i].tickSpacing, true); // reverts on duplicate
        }
    }
}
