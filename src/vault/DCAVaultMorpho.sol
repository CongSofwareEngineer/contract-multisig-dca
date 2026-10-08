// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DCAVaultRoles} from "./DCAVaultRoles.sol";

/// @title DCAVaultMorpho
/// @notice USDC <-> MetaMorpho (ERC-4626): deposit, operator supply / withdraw, vault migration, balance views.
/// @dev `receiver` / `owner` are always address(this); approvals are exact and reset to 0 (invariants 2, 3).
abstract contract DCAVaultMorpho is DCAVaultRoles {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Anyone
    // ------------------------------------------------------------------

    /// @notice Deposits USDC from the caller and supplies it to Morpho in the same tx.
    /// @dev Not gated by `paused`: adding funds is always safe. Only USDC can enter this way.
    /// @param amount USDC amount (6 decimals); caller must have approved this contract
    function depositAndSupply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = _supplyToMorpho(amount);
        emit Deposited(msg.sender, amount, shares);
    }

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Supplies idle USDC held by the vault to Morpho (e.g. USDC transferred in directly).
    /// @param amount USDC amount, at most the idle balance
    function morphoDeposit(uint256 amount) external onlyOperator whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > IERC20(usdc).balanceOf(address(this))) revert InsufficientBalance();
        uint256 shares = _supplyToMorpho(amount);
        emit MorphoDeposited(amount, shares);
    }

    /// @notice Withdraws exactly `amount` USDC from Morpho back into the vault.
    /// @param amount USDC amount to withdraw
    function morphoWithdraw(uint256 amount) external onlyOperator whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 shares = _withdrawFromMorpho(amount);
        emit MorphoWithdrawn(amount, shares);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice USDC idle in the vault + USDC value of the vault's Morpho shares.
    function totalUsdc() external view returns (uint256) {
        return IERC20(usdc).balanceOf(address(this)) + _usdcInMorpho();
    }

    /// @notice Balance snapshot: USDC idle, USDC in Morpho, and the balance of every whitelisted token.
    /// @dev Only whitelisted tokens are read, so a junk token can never make this revert.
    /// @return usdcIdle USDC held directly by the vault
    /// @return usdcInMorpho USDC value of the vault's Morpho shares
    /// @return tokens whitelisted tokens (includes USDC, WETH, cbBTC)
    /// @return balances `balanceOf(vault)` for each entry in `tokens`
    function getBalances()
        external
        view
        returns (uint256 usdcIdle, uint256 usdcInMorpho, address[] memory tokens, uint256[] memory balances)
    {
        usdcIdle = IERC20(usdc).balanceOf(address(this));
        usdcInMorpho = _usdcInMorpho();
        tokens = _allowedTokenList;
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _supplyToMorpho(uint256 amount) internal returns (uint256 shares) {
        address vault = morphoVault;
        IERC20(usdc).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit(amount, address(this)); // receiver hardcoded
        IERC20(usdc).forceApprove(vault, 0);
    }

    function _withdrawFromMorpho(uint256 amount) internal returns (uint256 shares) {
        // receiver and owner hardcoded to the vault (invariant 2).
        shares = IERC4626(morphoVault).withdraw(amount, address(this), address(this));
    }

    /// @dev Makes sure `amount` USDC is idle in the vault, pulling the shortfall from Morpho.
    ///      `type(uint256).max` redeems every share and returns the whole USDC balance.
    function _prepareUsdc(uint256 amount) internal returns (uint256) {
        IERC4626 vault = IERC4626(morphoVault);
        if (amount == type(uint256).max) {
            uint256 shares = vault.balanceOf(address(this));
            if (shares > 0) {
                uint256 assets = vault.redeem(shares, address(this), address(this));
                emit MorphoWithdrawn(assets, shares);
            }
            amount = IERC20(usdc).balanceOf(address(this));
            if (amount == 0) revert InsufficientBalance();
            return amount;
        }
        uint256 idle = IERC20(usdc).balanceOf(address(this));
        if (idle < amount) {
            uint256 missing = amount - idle;
            uint256 burned = _withdrawFromMorpho(missing);
            emit MorphoWithdrawn(missing, burned);
        }
        return amount;
    }

    /// @dev Redeems every share in the old vault, then supplies the full USDC balance to the new one.
    function _changeMorphoVault(address newVault) internal {
        if (newVault == address(0)) revert ZeroAddress();
        address oldVault = morphoVault;
        if (newVault == oldVault) revert SameMorphoVault();
        if (IERC4626(newVault).asset() != usdc) revert VaultAssetMismatch();

        uint256 shares = IERC4626(oldVault).balanceOf(address(this));
        if (shares > 0) {
            IERC4626(oldVault).redeem(shares, address(this), address(this));
        }
        morphoVault = newVault; // before _supplyToMorpho, which reads morphoVault

        uint256 migrated = IERC20(usdc).balanceOf(address(this));
        if (migrated > 0) {
            _supplyToMorpho(migrated);
        }
        emit MorphoVaultChanged(oldVault, newVault, migrated);
    }

    function _usdcInMorpho() internal view returns (uint256) {
        IERC4626 vault = IERC4626(morphoVault);
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }
}
