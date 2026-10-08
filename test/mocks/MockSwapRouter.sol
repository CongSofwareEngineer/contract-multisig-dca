// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Fake SwapRouter02: pulls exactly amountIn, mints `amountIn * num / den` of tokenOut to recipient.
///      Test-only knobs simulate a malicious router.
contract MockSwapRouter is ISwapRouter02 {
    mapping(address => mapping(address => uint256)) public rateNum;
    mapping(address => mapping(address => uint256)) public rateDen;

    /// @dev If set, the router tries to pull more than amountIn (must fail: allowance is exact).
    bool public pullExtra;
    /// @dev If set, the router reports a huge amountOut but delivers only `amountIn*rate` / 2.
    bool public lieAboutOutput;
    /// @dev Records the last recipient so tests can assert it is always the vault.
    address public lastRecipient;

    function setRate(address tokenIn, address tokenOut, uint256 num, uint256 den) external {
        rateNum[tokenIn][tokenOut] = num;
        rateDen[tokenIn][tokenOut] = den;
    }

    function setPullExtra(bool v) external {
        pullExtra = v;
    }

    function setLieAboutOutput(bool v) external {
        lieAboutOutput = v;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        lastRecipient = p.recipient;
        uint256 pullAmount = pullExtra ? p.amountIn + 1 : p.amountIn;
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), pullAmount);
        amountOut = p.amountIn * rateNum[p.tokenIn][p.tokenOut] / rateDen[p.tokenIn][p.tokenOut];
        if (lieAboutOutput) {
            MockERC20(p.tokenOut).mint(p.recipient, amountOut / 2);
            return type(uint128).max;
        }
        require(amountOut >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
