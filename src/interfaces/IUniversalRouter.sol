// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap UniversalRouter interface. Reserved for Phase 2 (swapExactInputV4).
/// @dev When Phase 2 is built, DCAVault must build `commands`/`inputs` itself — it never forwards
///      raw calldata from the operator.
interface IUniversalRouter {
    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
