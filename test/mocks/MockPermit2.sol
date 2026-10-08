// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";

/// @dev Fake Permit2 AllowanceTransfer: same allowance / expiration semantics as the real one
///      (expiration 0 = this block, expired when block.timestamp > expiration, amount decremented).
contract MockPermit2 is IPermit2 {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }

    mapping(address => mapping(address => mapping(address => Allowance))) internal _allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        _allowance[msg.sender][token][spender] =
            Allowance(amount, expiration == 0 ? uint48(block.timestamp) : expiration);
    }

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Allowance memory a = _allowance[owner][token][spender];
        return (a.amount, a.expiration, 0);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = _allowance[from][token][msg.sender];
        require(block.timestamp <= a.expiration, "AllowanceExpired");
        require(a.amount >= amount, "InsufficientAllowance");
        a.amount -= amount;
        IERC20(token).transferFrom(from, to, amount);
    }
}
