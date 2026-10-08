// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DCAVaultMorpho} from "./DCAVaultMorpho.sol";

/// @title DCAVaultProposals
/// @notice Multisig governance: `pause()`, propose / approve / execute / cancel and every proposal handler
///         that is not a plain role setter (WithdrawBatch, Unpause, protocol address changes, dispatch).
/// @dev Votes are re-counted against the live signer set at execute time (invariant 6).
abstract contract DCAVaultProposals is DCAVaultMorpho {
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
    ///         Never affects other pending proposals.
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

    /// @notice Votes against a pending proposal; cancels it once valid rejections reach the threshold
    ///         (>= 50% of current signers). Each signer votes once per proposal: approve OR reject.
    /// @dev A single signer can never cancel someone else's proposal on their own (except the 2-signer
    ///      case, where the threshold is 1 for approving and rejecting alike).
    /// @param id proposal id
    function reject(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        _requirePending(p);
        if (hasApproved[id][msg.sender] || hasRejected[id][msg.sender]) revert AlreadyVoted();

        hasRejected[id][msg.sender] = true;
        emit ProposalRejected(id, msg.sender);

        // Same live re-count as approvals: rejections from removed signers do not count.
        if (_countValidRejections(id) >= getThreshold()) {
            p.cancelled = true;
            emit ProposalCancelled(id);
        }
    }

    /// @notice Cancels a pending proposal. Only its proposer, while still a signer, can cancel.
    /// @dev `onlySigner`: a removed signer must not keep any power over proposals, cancel included.
    /// @param id proposal id
    function cancel(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert ProposalNotFound();
        if (msg.sender != p.proposer) revert NotProposer();
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalIsCancelled();
        p.cancelled = true;
        emit ProposalCancelled(id);
    }

    /// @notice Proposes withdrawing the stable and / or whitelisted tokens to a whitelisted address.
    /// @param tokens `stableToken` or whitelisted tradable tokens (address(0) = native ETH, if whitelisted)
    /// @param amounts amounts per token; `type(uint256).max` = everything (stable: incl. all Morpho shares)
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

    /// @notice Proposes moving all stable to a new MetaMorpho vault (redeem all -> deposit all).
    /// @param newVault Morpho vault (ERC-4626) for `stableToken`; not validated on-chain
    function proposeChangeMorphoVault(address newVault) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.ChangeMorphoVault, abi.encode(newVault));
    }

    /// @notice Proposes whitelisting a tradable token.
    /// @param token token to whitelist; address(0) = native ETH (V4 only); must not be `stableToken`
    function proposeAddToken(address token) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.AddToken, abi.encode(token));
    }

    /// @notice Proposes removing a tradable token from the whitelist.
    /// @dev Its remaining balance can no longer be swapped or withdrawn until it is whitelisted again.
    /// @param token token to remove
    function proposeRemoveToken(address token) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.RemoveToken, abi.encode(token));
    }

    /// @notice Proposes allowing / disallowing one pool (stable <-> `token`) for operator swaps.
    /// @dev Signers must check the pool exists with real liquidity before approving: an allowed pool that does
    ///      not exist yet can be created and seeded by anyone (incl. an attacker holding the operator key).
    /// @param token tradable token side of the pool (address(0) = native ETH, V4 only)
    /// @param fee pool fee in hundredths of a bip, in [1, MAX_POOL_FEE]
    /// @param tickSpacing `V3_POOL` (0) for the Uniswap V3 pool, or the V4 tick spacing in [1, 32767]
    /// @param allowed true to add the entry, false to remove it
    function proposeSetAllowedPool(address token, uint24 fee, int24 tickSpacing, bool allowed)
        external
        onlySigner
        nonReentrant
        returns (uint256)
    {
        return _propose(ProposalType.SetAllowedPool, abi.encode(token, fee, tickSpacing, allowed));
    }

    /// @notice Proposes replacing the Uniswap V3 SwapRouter02 used by operator swaps.
    /// @dev Not validated on-chain (same trust model as `ChangeMorphoVault`): signers must check the
    ///      address before approving, because operator swaps hand `tokenIn` to this router.
    /// @param newRouter new SwapRouter02 address
    function proposeChangeUniV3Router(address newRouter) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.ChangeUniV3Router, abi.encode(newRouter));
    }

    /// @notice Proposes replacing the Permit2 address (used by V4 swaps).
    /// @param newPermit2 new Permit2 address
    function proposeChangePermit2(address newPermit2) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.ChangePermit2, abi.encode(newPermit2));
    }

    /// @notice Proposes replacing the Uniswap UniversalRouter address (used by V4 swaps).
    /// @param newRouter new UniversalRouter address
    function proposeChangeUniversalRouter(address newRouter) external onlySigner nonReentrant returns (uint256) {
        return _propose(ProposalType.ChangeUniversalRouter, abi.encode(newRouter));
    }

    /// @notice Proposes replacing the stable. On execution every unit of the old stable (idle + all Morpho
    ///         shares) is sent to `to` first, then `stableToken` and `morphoVault` switch together.
    /// @param newStable new stablecoin; must not be a whitelisted tradable token
    /// @param newVault Morpho vault (ERC-4626) for `newStable`; not validated on-chain
    /// @param to whitelisted withdraw address that receives the old stable
    function proposeChangeStableToken(address newStable, address newVault, address to)
        external
        onlySigner
        nonReentrant
        returns (uint256)
    {
        return _propose(ProposalType.ChangeStableToken, abi.encode(newStable, newVault, to));
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

    /// @notice Rejections from addresses that are signers right now.
    /// @param id proposal id
    /// @return valid rejection count (cancelled once it reaches `getThreshold()`)
    function getRejections(uint256 id) external view returns (uint256) {
        if (proposals[id].createdAt == 0) revert ProposalNotFound();
        return _countValidRejections(id);
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
        _requirePending(p);
        if (hasApproved[id][msg.sender]) revert AlreadyApproved();
        if (hasRejected[id][msg.sender]) revert AlreadyVoted();

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
                if (tokens[i] != stableToken && !allowedToken[tokens[i]]) revert TokenNotAllowed();
                if (amounts[i] == 0) revert ZeroAmount();
            }
        } else if (pType == ProposalType.ChangeStableToken) {
            (address newStable, address newVault, address to) = abi.decode(data, (address, address, address));
            if (newStable == address(0) || newVault == address(0)) revert ZeroAddress();
            if (newStable == stableToken) revert SameAddress();
            if (newVault == morphoVault) revert SameMorphoVault();
            if (allowedToken[newStable]) revert StableNotTradable();
            if (!isWithdrawAddress[to]) revert WithdrawAddressNotAllowed();
        } else if (pType == ProposalType.AddToken) {
            // address(0) is valid here: it means native ETH.
            address token = abi.decode(data, (address));
            if (token == stableToken) revert StableNotTradable();
        } else if (pType == ProposalType.RemoveToken) {
            abi.decode(data, (address)); // address(0) valid (native ETH); existence checked at execution
        } else if (pType == ProposalType.SetAllowedPool) {
            (address token, uint24 fee, int24 tickSpacing, bool allowed) =
                abi.decode(data, (address, uint24, int24, bool));
            if (allowed) _checkPoolConfig(token, fee, tickSpacing); // existence (add / remove) checked at execution
        } else if (pType == ProposalType.Unpause) {
            if (data.length != 0) revert BadArrayLength();
        } else {
            address a = abi.decode(data, (address));
            if (a == address(0)) revert ZeroAddress();
            if (pType == ProposalType.AddSigner && (isSigner[a] || isOperator[a])) revert RoleConflict();
            if (pType == ProposalType.AddOperator && (isOperator[a] || isSigner[a])) revert RoleConflict();
            if (pType == ProposalType.RemoveSigner && signers.length <= MIN_SIGNERS) revert TooFewSigners();
            if (pType == ProposalType.ChangeMorphoVault && a == morphoVault) revert SameMorphoVault();
            if (pType == ProposalType.ChangeUniV3Router && a == uniV3Router) revert SameAddress();
            if (pType == ProposalType.ChangePermit2 && a == permit2) revert SameAddress();
            if (pType == ProposalType.ChangeUniversalRouter && a == universalRouter) revert SameAddress();
        }
    }

    function _execute(ProposalType pType, bytes memory data) internal {
        if (pType == ProposalType.WithdrawBatch) {
            (address[] memory tokens, uint256[] memory amounts, address to) =
                abi.decode(data, (address[], uint256[], address));
            _withdrawBatch(tokens, amounts, to);
        } else if (pType == ProposalType.ChangeStableToken) {
            (address newStable, address newVault, address to) = abi.decode(data, (address, address, address));
            _changeStableToken(newStable, newVault, to);
        } else if (pType == ProposalType.SetAllowedPool) {
            (address token, uint24 fee, int24 tickSpacing, bool allowed) =
                abi.decode(data, (address, uint24, int24, bool));
            _setAllowedPool(token, fee, tickSpacing, allowed);
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
            else if (pType == ProposalType.RemoveToken) _removeToken(a);
            else if (pType == ProposalType.ChangeUniV3Router) _changeUniV3Router(a);
            else if (pType == ProposalType.ChangePermit2) _changePermit2(a);
            else _changeUniversalRouter(a); // ChangeUniversalRouter — the only remaining type
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
            uint256 amount = amounts[i];
            if (amount == 0) revert ZeroAmount();

            if (token == stableToken) {
                amount = _prepareStable(amount);
            } else {
                // Never call into a non-whitelisted token (invariant 12).
                if (!allowedToken[token]) revert TokenNotAllowed();
                uint256 bal = _balanceOf(token);
                if (amount == type(uint256).max) amount = bal;
                if (amount == 0 || amount > bal) revert InsufficientBalance();
            }
            _sendToken(token, to, amount);
            emit Withdrawn(token, to, amount);
        }
    }

    // Protocol address changes. No allowance migration needed: approvals are always reset to 0 in the
    // same tx (invariant 3), so the old address keeps no power over vault funds after the switch.

    function _changeUniV3Router(address newRouter) internal {
        if (newRouter == address(0)) revert ZeroAddress();
        address old = uniV3Router;
        if (newRouter == old) revert SameAddress();
        uniV3Router = newRouter;
        emit UniV3RouterChanged(old, newRouter);
    }

    function _changePermit2(address newPermit2) internal {
        if (newPermit2 == address(0)) revert ZeroAddress();
        address old = permit2;
        if (newPermit2 == old) revert SameAddress();
        permit2 = newPermit2;
        emit Permit2Changed(old, newPermit2);
    }

    function _changeUniversalRouter(address newRouter) internal {
        if (newRouter == address(0)) revert ZeroAddress();
        address old = universalRouter;
        if (newRouter == old) revert SameAddress();
        universalRouter = newRouter;
        emit UniversalRouterChanged(old, newRouter);
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

    function _countValidRejections(uint256 id) internal view returns (uint256 count) {
        uint256 len = signers.length;
        for (uint256 i; i < len; ++i) {
            if (hasRejected[id][signers[i]]) ++count;
        }
    }

    function _requirePending(Proposal storage p) internal view {
        if (p.createdAt == 0) revert ProposalNotFound();
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalIsCancelled();
        if (_isExpired(p)) revert ProposalExpired();
    }

    function _isExpired(Proposal storage p) internal view returns (bool) {
        return block.timestamp > uint256(p.createdAt) + PROPOSAL_TTL;
    }
}
