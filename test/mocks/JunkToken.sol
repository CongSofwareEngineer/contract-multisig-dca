// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Hostile token: every ERC20 call reverts, except a raw `airdrop` that just writes storage.
///      Used to prove the vault never touches non-whitelisted tokens (invariant 12).
contract JunkToken {
    mapping(address => uint256) internal _bal;

    function airdrop(address to, uint256 amount) external {
        _bal[to] += amount;
    }

    function balanceOf(address) external pure returns (uint256) {
        revert("junk: balanceOf");
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("junk: transfer");
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("junk: transferFrom");
    }

    function approve(address, uint256) external pure returns (bool) {
        revert("junk: approve");
    }

    function allowance(address, address) external pure returns (uint256) {
        revert("junk: allowance");
    }

    function decimals() external pure returns (uint8) {
        revert("junk: decimals");
    }
}
