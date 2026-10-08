// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultOperatorFns {
    function morphoWithdraw(uint256 amount) external;
}

/// @dev ERC-4626 that tries to re-enter the DCAVault during `deposit`. Must be blocked by nonReentrant.
contract ReentrantMorphoVault is ERC4626 {
    address public target;
    bool public armed;

    constructor(IERC20 asset_) ERC20("Reentrant", "RE") ERC4626(asset_) {}

    function arm(address t) external {
        target = t;
        armed = true;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (armed) {
            armed = false;
            IVaultOperatorFns(target).morphoWithdraw(1);
        }
        return super.deposit(assets, receiver);
    }
}
