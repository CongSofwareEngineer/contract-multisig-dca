// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Permit2 AllowanceTransfer interface. Used by `swapExactInputV4`.
interface IPermit2 {
    /// @notice Approves `spender` to spend `amount` of `token` via Permit2 until `expiration`.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    /// @notice Returns the Permit2 allowance of `spender` for `owner`'s `token`.
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
