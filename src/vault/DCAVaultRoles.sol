// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DCAVaultStorage} from "./DCAVaultStorage.sol";

/// @title DCAVaultRoles
/// @notice Signers, operators, withdraw addresses, token / fee whitelists and `getThreshold()`.
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

    /// @notice Returns all whitelisted tokens.
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

    function _addToken(address token) internal {
        if (token == address(0)) revert ZeroAddress();
        if (allowedToken[token]) revert Duplicate();
        allowedToken[token] = true;
        _allowedTokenList.push(token);
        emit TokenAllowed(token, true);
    }

    function _removeToken(address token) internal {
        if (token == usdc) revert CannotRemoveUsdc();
        if (!allowedToken[token]) revert NotFound();
        allowedToken[token] = false;
        _removeFromArray(_allowedTokenList, token);
        emit TokenAllowed(token, false);
    }

    function _setAllowedFee(uint24 fee, bool allowed) internal {
        if (fee == 0) revert InvalidFee();
        allowedFee[fee] = allowed;
        emit FeeAllowed(fee, allowed);
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
