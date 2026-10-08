// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DCAVaultStorage} from "./DCAVaultStorage.sol";

/// @title DCAVaultRoles
/// @notice Signers, operators, withdraw addresses, token / pool whitelists and `getThreshold()`.
/// @dev Internal setters are called from the constructor and from proposal execution only.
///      signer ∩ operator = ∅ is enforced here, so every path that adds a role goes through it.
abstract contract DCAVaultRoles is DCAVaultStorage {
    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Returns all current signers.
    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    /// @notice Returns all whitelisted tradable tokens (never includes `stableToken`; address(0) = native ETH).
    function getAllowedTokens() external view returns (address[] memory) {
        return _allowedTokenList;
    }

    /// @notice Approvals needed to execute: ≥ 50% of signers, rounded up. 2→1, 3→2, 4→2, 5→3.
    function getThreshold() public view returns (uint256) {
        return (signers.length + 1) / 2;
    }

    // ------------------------------------------------------------------
    // Internal: role & whitelist setters
    // ------------------------------------------------------------------

    function _addSigner(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        if (isSigner[a]) revert Duplicate();
        if (isOperator[a]) revert RoleConflict();
        isSigner[a] = true;
        signers.push(a);
        emit SignerAdded(a);
    }

    function _removeSigner(address a) internal {
        if (!isSigner[a]) revert NotFound();
        if (signers.length - 1 < MIN_SIGNERS) revert TooFewSigners();
        isSigner[a] = false;
        _removeFromArray(signers, a);
        emit SignerRemoved(a);
    }

    function _addOperator(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        if (isOperator[a]) revert Duplicate();
        if (isSigner[a]) revert RoleConflict();
        isOperator[a] = true;
        emit OperatorAdded(a);
    }

    function _removeOperator(address a) internal {
        if (!isOperator[a]) revert NotFound();
        isOperator[a] = false;
        emit OperatorRemoved(a);
    }

    function _addWithdrawAddress(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        if (isWithdrawAddress[a]) revert Duplicate();
        isWithdrawAddress[a] = true;
        emit WithdrawAddressAdded(a);
    }

    function _removeWithdrawAddress(address a) internal {
        if (!isWithdrawAddress[a]) revert NotFound();
        isWithdrawAddress[a] = false;
        emit WithdrawAddressRemoved(a);
    }

    /// @dev `token == NATIVE` (address(0)) is allowed on purpose: it whitelists native ETH for V4 pools.
    function _addToken(address token) internal {
        // Stable and tradable lists stay disjoint, so "is this the stable?" is always one address compare.
        if (token == stableToken) revert StableNotTradable();
        if (allowedToken[token]) revert Duplicate();
        allowedToken[token] = true;
        _allowedTokenList.push(token);
        emit TokenAllowed(token, true);
    }

    function _removeToken(address token) internal {
        if (!allowedToken[token]) revert NotFound();
        allowedToken[token] = false;
        _removeFromArray(_allowedTokenList, token);
        emit TokenAllowed(token, false);
    }

    /// @dev Adds or removes one (token, fee, tickSpacing) pool entry. Adding does not require the token to be
    ///      in `allowedToken` yet (swaps check both), so AddToken and SetAllowedPool can be proposed in parallel.
    function _setAllowedPool(address token, uint24 fee, int24 tickSpacing, bool allowed) internal {
        if (allowed) {
            _checkPoolConfig(token, fee, tickSpacing);
            if (allowedPool[token][fee][tickSpacing]) revert Duplicate();
            allowedPool[token][fee][tickSpacing] = true;
        } else {
            if (!allowedPool[token][fee][tickSpacing]) revert NotFound();
            allowedPool[token][fee][tickSpacing] = false;
        }
        emit PoolAllowed(token, fee, tickSpacing, allowed);
    }

    /// @dev Static checks for a new pool entry (also run at propose time).
    function _checkPoolConfig(address token, uint24 fee, int24 tickSpacing) internal view {
        // Every pool is stable <-> token, so the stable itself can never be the `token` side.
        if (token == stableToken) revert StableNotTradable();
        if (fee == 0 || fee > MAX_POOL_FEE) revert InvalidFee();
        // V3_POOL (0) or a valid V4 tick spacing [1, 32767].
        if (tickSpacing < V3_POOL || tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
        // SwapRouter02 cannot trade native ETH, so a V3 entry for it would be dead (and misleading).
        if (tickSpacing == V3_POOL && token == NATIVE) revert NativeNotSupported();
    }

    // ------------------------------------------------------------------
    // Private helpers
    // ------------------------------------------------------------------

    function _removeFromArray(address[] storage arr, address a) private {
        uint256 len = arr.length;
        for (uint256 i; i < len; ++i) {
            if (arr[i] == a) {
                arr[i] = arr[len - 1];
                arr.pop();
                return;
            }
        }
    }
}
