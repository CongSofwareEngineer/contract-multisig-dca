// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Plain OZ ERC-4626 standing in for a MetaMorpho vault in unit tests.
contract MockMorphoVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock Morpho USDC", "mmUSDC") ERC4626(asset_) {}
}
