// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DCAVaultRoles} from "./DCAVaultRoles.sol";

/// @title DCAVaultMorpho
/// @notice Stable <-> MetaMorpho (ERC-4626): deposit, operator supply / withdraw, vault / stable migration,
///         balance views and native-aware balance / transfer helpers.
/// @dev `receiver` / `owner` are always address(this); approvals are exact and reset to 0 (invariants 2, 3).
abstract contract DCAVaultMorpho is DCAVaultRoles {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Anyone
    // ------------------------------------------------------------------

    /// @notice Deposits `stableToken` from the caller and supplies it to Morpho in the same tx.
    /// @dev Not gated by `paused`: adding funds is always safe. Only the stable can enter this way.
    /// @param amount stable amount (stable's own decimals); caller must have approved this contract
    function depositAndSupply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(stableToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = _supplyToMorpho(amount);
        emit Deposited(msg.sender, amount, shares);
    }

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Supplies idle stable held by the vault to Morpho (e.g. stable transferred in directly).
    /// @param amount stable amount, at most the idle balance
    function morphoDeposit(uint256 amount) external onlyOperator whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > IERC20(stableToken).balanceOf(address(this))) revert InsufficientBalance();
        uint256 shares = _supplyToMorpho(amount);
        emit MorphoDeposited(amount, shares);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Stable idle in the vault + stable value of the vault's Morpho shares.
    function totalStable() external view returns (uint256) {
        return IERC20(stableToken).balanceOf(address(this)) + _stableInMorpho();
    }

    /// @notice Balance snapshot: stable idle, stable in Morpho, and the balance of every whitelisted tradable token.
    /// @dev Only whitelisted tokens are read, so a junk token can never make this revert.
    /// @return stableIdle stable held directly by the vault
    /// @return stableInMorpho stable value of the vault's Morpho shares
    /// @return tokens whitelisted tradable tokens (no stable; address(0) = native ETH)
    /// @return balances vault balance for each entry in `tokens` (native ETH: `address(this).balance`)
    function getBalances()
        external
        view
        returns (uint256 stableIdle, uint256 stableInMorpho, address[] memory tokens, uint256[] memory balances)
    {
        stableIdle = IERC20(stableToken).balanceOf(address(this));
        stableInMorpho = _stableInMorpho();
        tokens = _allowedTokenList;
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = _balanceOf(tokens[i]);
        }
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _supplyToMorpho(uint256 amount) internal returns (uint256 shares) {
        address vault = morphoVault;
        IERC20(stableToken).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit(amount, address(this)); // receiver hardcoded
        IERC20(stableToken).forceApprove(vault, 0);
    }

    function _withdrawFromMorpho(uint256 amount) internal returns (uint256 shares) {
        // receiver and owner hardcoded to the vault (invariant 2).
        shares = IERC4626(morphoVault).withdraw(amount, address(this), address(this));
    }

    /// @dev Makes sure `amount` stable is idle in the vault, pulling the shortfall from Morpho.
    ///      `type(uint256).max` redeems every share and returns the whole stable balance (may be 0).
    function _prepareStable(uint256 amount) internal returns (uint256) {
        IERC4626 vault = IERC4626(morphoVault);
        if (amount == type(uint256).max) {
            uint256 shares = vault.balanceOf(address(this));
            if (shares > 0) {
                uint256 assets = vault.redeem(shares, address(this), address(this));
                emit MorphoWithdrawn(assets, shares);
            }
            return IERC20(stableToken).balanceOf(address(this));
        }
        uint256 idle = IERC20(stableToken).balanceOf(address(this));
        if (idle < amount) {
            uint256 missing = amount - idle;
            uint256 burned = _withdrawFromMorpho(missing);
            emit MorphoWithdrawn(missing, burned);
        }
        return amount;
    }

    /// @dev Redeems every share in the old vault, then supplies the full stable balance to the new one.
    ///      `newVault` is whatever address the signers approved — no factory / asset() check by design.
    function _changeMorphoVault(address newVault) internal {
        if (newVault == address(0)) revert ZeroAddress();
        address oldVault = morphoVault;
        if (newVault == oldVault) revert SameMorphoVault();

        uint256 shares = IERC4626(oldVault).balanceOf(address(this));
        if (shares > 0) {
            IERC4626(oldVault).redeem(shares, address(this), address(this));
        }
        morphoVault = newVault; // before _supplyToMorpho, which reads morphoVault

        uint256 migrated = IERC20(stableToken).balanceOf(address(this));
        if (migrated > 0) {
            _supplyToMorpho(migrated);
        }
        emit MorphoVaultChanged(oldVault, newVault, migrated);
    }

    /// @dev Swaps the stable itself. Every unit of the old stable (idle + all Morpho shares) is first sent to
    ///      `to`, so nothing is stranded; doing the sweep here (not as a precondition) means nobody can block the
    ///      change by donating 1 wei of old stable. After this the old stable is just an unlisted token.
    ///      `newVault` must be a Morpho vault for `newStable` — not validated on-chain (same as ChangeMorphoVault).
    function _changeStableToken(address newStable, address newVault, address to) internal {
        if (newStable == address(0) || newVault == address(0)) revert ZeroAddress();
        address oldStable = stableToken;
        address oldVault = morphoVault;
        if (newStable == oldStable) revert SameAddress();
        if (newVault == oldVault) revert SameMorphoVault();
        // Keep stable / tradable lists disjoint: remove it from `allowedToken` first if it was tradable.
        if (allowedToken[newStable]) revert StableNotTradable();
        if (!isWithdrawAddress[to]) revert WithdrawAddressNotAllowed();

        uint256 shares = IERC4626(oldVault).balanceOf(address(this));
        if (shares > 0) {
            uint256 assets = IERC4626(oldVault).redeem(shares, address(this), address(this));
            emit MorphoWithdrawn(assets, shares);
        }
        uint256 swept = IERC20(oldStable).balanceOf(address(this));
        if (swept > 0) {
            IERC20(oldStable).safeTransfer(to, swept);
            emit Withdrawn(oldStable, to, swept);
        }

        stableToken = newStable;
        morphoVault = newVault;
        stableChangedAt = uint64(block.timestamp); // expires every pending proposal (see `_isExpired`)
        emit StableTokenChanged(oldStable, newStable, oldVault, newVault, swept);
    }

    /// @dev Native-aware balance: `NATIVE` (address(0)) reads the ETH balance. Callers only pass the stable
    ///      or a whitelisted token (invariant 12).
    function _balanceOf(address token) internal view returns (uint256) {
        return token == NATIVE ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev Native-aware transfer out. Only reached from `WithdrawBatch` / stable sweep, always to a whitelisted
    ///      withdraw address, with empty calldata — never an arbitrary call.
    function _sendToken(address token, address to, uint256 amount) internal {
        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _stableInMorpho() internal view returns (uint256) {
        IERC4626 vault = IERC4626(morphoVault);
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }
}
