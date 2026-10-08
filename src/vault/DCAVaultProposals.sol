// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DCAVaultMorpho} from "./DCAVaultMorpho.sol";

/// @title DCAVaultProposals
/// @notice Multisig governance: `pause()`, propose / approve / execute / cancel and every proposal handler
///         that is not a plain role setter (WithdrawBatch, Unpause, dispatch).
/// @dev Votes are re-counted against the live signer set at execute time (invariant 6).
abstract contract DCAVaultProposals is DCAVaultMorpho {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Signer: pause + proposals
    // ------------------------------------------------------------------

    /// @notice Immediately pauses all operator functions. One signer is enough (pausing cannot lose
    ///         funds). Unpausing requires an `Unpause` proposal.
    function pause() external onlySigner {
        if (paused) revert IsPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Creates a proposal; the proposer auto-approves, so it may execute immediately.
    /// @param pType proposal type
    /// @param data abi-encoded payload for `pType` (see DCA_VAULT_SPEC.md section 5.3)
    /// @return id the new proposal id
    function propose(ProposalType pType, bytes calldata data) external onlySigner nonReentrant returns (uint256 id) {
        id = _propose(pType, data);
    }

    /// @notice Approves a pending proposal; executes it once valid approvals reach the threshold.
    /// @param id proposal id
    function approve(uint256 id) external onlySigner nonReentrant {
        _approve(id);
    }

    /// @notice Cancels a pending proposal. Only its proposer can cancel.
    /// @param id proposal id
    function cancel(uint256 id) external {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert ProposalNotFound();
        if (msg.sender != p.proposer) revert NotProposer();
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalIsCancelled();
        p.cancelled = true;
        emit ProposalCancelled(id);
    }

    /// @notice Proposes withdrawing whitelisted tokens to a whitelisted address.
    /// @param tokens whitelisted tokens
    /// @param amounts amounts per token; `type(uint256).max` = everything (USDC: incl. all Morpho shares)
    /// @param to whitelisted withdraw address
    function proposeWithdrawBatch(address[] calldata tokens, uint256[] calldata amounts, address to)
        external
        onlySigner
        nonReentrant
        returns (uint256)
    {
        return _propose(ProposalType.WithdrawBatch, abi.encode(tokens, amounts, to));
    }

    /// @notice Proposes adding a withdraw address.
    /// @param account address to whitelist
    function proposeAddWithdrawAddress(address account) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.AddWithdrawAddress, abi.encode(account));
    }

    /// @notice Proposes removing a withdraw address.
    /// @param account address to remove
    function proposeRemoveWithdrawAddress(address account) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.RemoveWithdrawAddress, abi.encode(account));
    }

    /// @notice Proposes adding a signer.
    /// @param account new signer (must not be an operator)
    function proposeAddSigner(address account) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.AddSigner, abi.encode(account));
    }

    /// @notice Proposes removing a signer (at least `MIN_SIGNERS` must remain).
    /// @param account signer to remove
    function proposeRemoveSigner(address account) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.RemoveSigner, abi.encode(account));
    }

    /// @notice Proposes adding an operator.
    /// @param account new operator (must not be a signer)
    function proposeAddOperator(address account) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.AddOperator, abi.encode(account));
    }

    /// @notice Proposes removing an operator (removing all operators is allowed).
    /// @param account operator to remove
    function proposeRemoveOperator(address account) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.RemoveOperator, abi.encode(account));
    }

    /// @notice Proposes moving all USDC to a new MetaMorpho vault (redeem all -> deposit all).
    /// @param newVault ERC-4626 vault whose `asset()` is USDC
    function proposeChangeMorphoVault(address newVault) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.ChangeMorphoVault, abi.encode(newVault));
    }

    /// @notice Proposes whitelisting a token.
    /// @param token token to whitelist
    function proposeAddToken(address token) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.AddToken, abi.encode(token));
    }

    /// @notice Proposes removing a token from the whitelist (USDC cannot be removed).
    /// @param token token to remove
    function proposeRemoveToken(address token) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.RemoveToken, abi.encode(token));
    }

    /// @notice Proposes allowing / disallowing a Uniswap fee tier.
    /// @param fee fee tier in hundredths of a bip
    /// @param allowed new status
    function proposeSetAllowedFee(uint24 fee, bool allowed) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.SetAllowedFee, abi.encode(fee, allowed));
    }

    /// @notice Proposes unpausing operator functions.
    function proposeUnpause() external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.Unpause, "");
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Full proposal view.
    /// @param id proposal id
    /// @return pType proposal type
    /// @return data abi-encoded payload
    /// @return approvals approvals from addresses that are signers right now
    /// @return threshold current threshold
    /// @return executed whether it has executed
    /// @return cancelled whether it was cancelled
    /// @return expired whether the 7-day window has passed
    function getProposal(uint256 id)
        external
        view
        returns (
            ProposalType pType,
            bytes memory data,
            uint256 approvals,
            uint256 threshold,
            bool executed,
            bool cancelled,
            bool expired
        )
    {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert ProposalNotFound();
        return (p.pType, p.data, _countValidApprovals(id), getThreshold(), p.executed, p.cancelled, _isExpired(p));
    }

    // ------------------------------------------------------------------
    // Internal: proposals
    // ------------------------------------------------------------------

    /// @dev Helpers call this directly — never `this.propose()`, which would make msg.sender the vault.
    function _propose(ProposalType pType, bytes memory data) internal returns (uint256 id) {
        _validate(pType, data);
        id = ++proposalCount; // ids start at 1 so `createdAt == 0` / id 0 always means "not found"
        Proposal storage p = proposals[id];
        p.pType = pType;
        p.data = data;
        p.proposer = msg.sender;
        p.createdAt = uint64(block.timestamp);
        emit ProposalCreated(id, pType, msg.sender);
        _approve(id);
    }

    function _approve(uint256 id) internal {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert ProposalNotFound();
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalIsCancelled();
        if (_isExpired(p)) revert ProposalExpired();
        if (hasApproved[id][msg.sender]) revert AlreadyApproved();

        hasApproved[id][msg.sender] = true;
        emit ProposalApproved(id, msg.sender);

        // Re-count at execute time: votes from removed signers do not count (invariant 6).
        if (_countValidApprovals(id) >= getThreshold()) {
            p.executed = true; // effect before any external interaction
            _execute(p.pType, p.data);
            emit ProposalExecuted(id);
        }
    }

    /// @dev Propose-time sanity check so obviously-invalid proposals are rejected early.
    ///      Every handler re-checks against live state when it executes.
    function _validate(ProposalType pType, bytes memory data) internal view {
        if (pType == ProposalType.WithdrawBatch) {
            (address[] memory tokens, uint256[] memory amounts, address to) =
                abi.decode(data, (address[], uint256[], address));
            if (tokens.length == 0 || tokens.length != amounts.length) revert BadArrayLength();
            if (!isWithdrawAddress[to]) revert WithdrawAddressNotAllowed();
            for (uint256 i; i < tokens.length; ++i) {
                if (!allowedToken[tokens[i]]) revert TokenNotAllowed();
                if (amounts[i] == 0) revert ZeroAmount();
            }
        } else if (pType == ProposalType.SetAllowedFee) {
            (uint24 fee,) = abi.decode(data, (uint24, bool));
            if (fee == 0) revert InvalidFee();
        } else if (pType == ProposalType.Unpause) {
            if (data.length != 0) revert BadArrayLength();
        } else {
            address a = abi.decode(data, (address));
            if (a == address(0)) revert ZeroAddress();
            if (pType == ProposalType.AddSigner && (isSigner[a] || isOperator[a])) revert RoleConflict();
            if (pType == ProposalType.AddOperator && (isOperator[a] || isSigner[a])) revert RoleConflict();
            if (pType == ProposalType.RemoveSigner && signers.length <= MIN_SIGNERS) revert TooFewSigners();
            if (pType == ProposalType.RemoveToken && a == usdc) revert CannotRemoveUsdc();
            if (pType == ProposalType.ChangeMorphoVault && IERC4626(a).asset() != usdc) revert VaultAssetMismatch();
        }
    }

    function _execute(ProposalType pType, bytes memory data) internal {
        if (pType == ProposalType.WithdrawBatch) {
            (address[] memory tokens, uint256[] memory amounts, address to) =
                abi.decode(data, (address[], uint256[], address));
            _withdrawBatch(tokens, amounts, to);
        } else if (pType == ProposalType.SetAllowedFee) {
            (uint24 fee, bool allowed) = abi.decode(data, (uint24, bool));
            _setAllowedFee(fee, allowed);
        } else if (pType == ProposalType.Unpause) {
            if (!paused) revert NotPaused();
            paused = false;
            emit Unpaused();
        } else {
            address a = abi.decode(data, (address));
            if (pType == ProposalType.AddWithdrawAddress) _addWithdrawAddress(a);
            else if (pType == ProposalType.RemoveWithdrawAddress) _removeWithdrawAddress(a);
            else if (pType == ProposalType.AddSigner) _addSigner(a);
            else if (pType == ProposalType.RemoveSigner) _removeSigner(a);
            else if (pType == ProposalType.AddOperator) _addOperator(a);
            else if (pType == ProposalType.RemoveOperator) _removeOperator(a);
            else if (pType == ProposalType.ChangeMorphoVault) _changeMorphoVault(a);
            else if (pType == ProposalType.AddToken) _addToken(a);
            else _removeToken(a); // RemoveToken — the only remaining type
        }
    }

    // ------------------------------------------------------------------
    // Internal: proposal handlers
    // ------------------------------------------------------------------

    function _withdrawBatch(address[] memory tokens, uint256[] memory amounts, address to) internal {
        if (!isWithdrawAddress[to]) revert WithdrawAddressNotAllowed();
        uint256 len = tokens.length;
        if (len == 0 || len != amounts.length) revert BadArrayLength();

        for (uint256 i; i < len; ++i) {
            address token = tokens[i];
            // Never call into a non-whitelisted token (invariant 12).
            if (!allowedToken[token]) revert TokenNotAllowed();
            uint256 amount = amounts[i];
            if (amount == 0) revert ZeroAmount();

            if (token == usdc) {
                amount = _prepareUsdc(amount);
            } else {
                uint256 bal = IERC20(token).balanceOf(address(this));
                if (amount == type(uint256).max) amount = bal;
                if (amount == 0 || amount > bal) revert InsufficientBalance();
            }
            IERC20(token).safeTransfer(to, amount);
            emit Withdrawn(token, to, amount);
        }
    }

    // ------------------------------------------------------------------
    // Internal: views
    // ------------------------------------------------------------------

    function _countValidApprovals(uint256 id) internal view returns (uint256 count) {
        uint256 len = signers.length;
        for (uint256 i; i < len; ++i) {
            if (hasApproved[id][signers[i]]) ++count;
        }
    }

    function _isExpired(Proposal storage p) internal view returns (bool) {
        return block.timestamp > uint256(p.createdAt) + PROPOSAL_TTL;
    }
}
