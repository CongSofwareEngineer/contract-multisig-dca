// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DCAVaultStorage} from "./vault/DCAVaultStorage.sol";
import {DCAVaultSwap} from "./vault/DCAVaultSwap.sol";
import {DCAVaultProposals} from "./vault/DCAVaultProposals.sol";

/// @title DCAVault
/// @notice Immutable multisig-governed vault on Base that DCAs USDC into cbBTC / WETH.
///         Idle USDC always sits in a MetaMorpho (ERC-4626) vault. An off-chain bot, holding an
///         `operator` key, can only swap whitelisted tokens and move USDC in/out of Morpho.
///         Tokens leave the contract only through a threshold-approved `WithdrawBatch` proposal,
///         and only to a whitelisted withdraw address.
/// @dev Security model (see DCA_VAULT_SPEC.md section 10):
///      - no standing approvals: approve exact -> use -> reset to 0 in the same call
///      - swap / Morpho output always goes to address(this), never to a parameter
///      - no delegatecall, no selfdestruct, no arbitrary call, no receive()/fallback()
///      - never touches a token outside `allowedToken` (junk tokens are ignored, no rescue)
///      Code is split into modules (all compiled into this one immutable contract — no proxy):
///      - DCAVaultStorage   : types, constants, immutables, state, events, errors, modifiers
///      - DCAVaultRoles     : signers / operators / withdraw addresses / token & fee whitelists
///      - DCAVaultMorpho    : depositAndSupply, morphoDeposit / morphoWithdraw, vault migration
///      - DCAVaultSwap      : swapExactInputV3, withdrawAndSwapV3, V4 stub
///      - DCAVaultProposals : pause, propose / approve / cancel, proposal execution
contract DCAVault is DCAVaultSwap, DCAVaultProposals {
    /// @param _usdc USDC token (must also appear in `_tokens`)
    /// @param _uniV3Router Uniswap V3 SwapRouter02
    /// @param _permit2 Permit2 (Phase 2)
    /// @param _universalRouter Uniswap UniversalRouter (Phase 2)
    /// @param _morphoVault MetaMorpho vault whose `asset()` is USDC
    /// @param _signers initial signers, at least `MIN_SIGNERS`
    /// @param _operators initial operators (may be empty), disjoint from `_signers`
    /// @param _withdrawAddresses initial withdraw whitelist
    /// @param _tokens initial token whitelist (must include `_usdc`)
    /// @param _fees initial Uniswap fee tiers (spec default: 500, 3000)
    constructor(
        address _usdc,
        address _uniV3Router,
        address _permit2,
        address _universalRouter,
        address _morphoVault,
        address[] memory _signers,
        address[] memory _operators,
        address[] memory _withdrawAddresses,
        address[] memory _tokens,
        uint24[] memory _fees
    ) DCAVaultStorage(_usdc, _uniV3Router, _permit2, _universalRouter, _morphoVault) {
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
            _addToken(_tokens[i]);
        }
        if (!allowedToken[_usdc]) revert UsdcNotAllowed();
        for (uint256 i; i < _fees.length; ++i) {
            if (allowedFee[_fees[i]]) revert Duplicate();
            _setAllowedFee(_fees[i], true);
        }
    }
}
