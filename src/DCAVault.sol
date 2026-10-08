// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";

/// @title DCAVault
/// @notice Immutable multisig-governed vault on Base that DCAs USDC into cbBTC / WETH.
///         Idle USDC always sits in a MetaMorpho (ERC-4626) vault. An off-chain bot, holding an
///         `operator` key, can only swap whitelisted tokens and move USDC in/out of Morpho.
///         Tokens leave the contract only through a threshold-approved `WithdrawBatch` proposal,
///         and only to a whitelisted withdraw address.
/// @dev Security model (see DCA_VAULT_SPEC.md section 10):
///      - no standing approvals: approve exact -> use -> reset to 0 in the same call
///      - swap / Morpho output always goes to address(this), never to a parameter
///      - no delegatecall, no selfdestruct, no arbitrary call, no receive()/fallback()
///      - never touches a token outside `allowedToken` (junk tokens are ignored, no rescue)
contract DCAVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum ProposalType {
        WithdrawBatch,
        AddWithdrawAddress,
        RemoveWithdrawAddress,
        AddSigner,
        RemoveSigner,
        AddOperator,
        RemoveOperator,
        ChangeMorphoVault,
        AddToken,
        RemoveToken,
        SetAllowedFee,
        Unpause
    }

    struct Proposal {
        ProposalType pType;
        bytes data;
        address proposer;
        uint64 createdAt;
        bool executed;
        bool cancelled;
    }

    // ------------------------------------------------------------------
    // Constants & immutables
    // ------------------------------------------------------------------

    /// @notice Signer count can never drop below this.
    uint256 public constant MIN_SIGNERS = 2;
    /// @notice A proposal can only be approved / executed within this window after creation.
    uint256 public constant PROPOSAL_TTL = 7 days;
    /// @notice `version` value emitted in `Swapped` for Uniswap V3 swaps.
    uint8 public constant SWAP_VERSION_V3 = 3;

    address public immutable usdc;
    address public immutable uniV3Router;
    /// @dev Phase 2 (V4). Stored now so the deployed contract does not need to change later.
    address public immutable permit2;
    /// @dev Phase 2 (V4).
    address public immutable universalRouter;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    /// @notice Current MetaMorpho USDC vault. Changed only via a `ChangeMorphoVault` proposal.
    address public morphoVault;

    mapping(address => bool) public isSigner;
    address[] public signers;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isWithdrawAddress;

    mapping(address => bool) public allowedToken;
    /// @dev Mirror of `allowedToken` so views can list whitelisted balances without ever
    ///      touching a non-whitelisted (possibly malicious) token.
    address[] private _allowedTokenList;
    mapping(uint24 => bool) public allowedFee;

    bool public paused;

    /// @dev Raw storage; `getProposal(id)` adds live vote count, threshold and expiry.
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasApproved;
    uint256 public proposalCount;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Deposited(address indexed from, uint256 usdcAmount, uint256 shares);
    event MorphoDeposited(uint256 assets, uint256 shares);
    event MorphoWithdrawn(uint256 assets, uint256 shares);
    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOut,
        uint8 version
    );
    event ProposalCreated(uint256 indexed id, ProposalType pType, address indexed proposer);
    event ProposalApproved(uint256 indexed id, address indexed signer);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event WithdrawAddressAdded(address indexed account);
    event WithdrawAddressRemoved(address indexed account);
    event MorphoVaultChanged(address oldVault, address newVault, uint256 migratedAssets);
    event TokenAllowed(address token, bool allowed);
    event FeeAllowed(uint24 fee, bool allowed);
    event Paused(address indexed by);
    event Unpaused();

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotSigner();
    error NotOperator();
    error NotProposer();
    error IsPaused();
    error NotPaused();
    error ZeroAddress();
    error ZeroAmount();
    error Duplicate();
    error RoleConflict();
    error TooFewSigners();
    error UsdcNotAllowed();
    error VaultAssetMismatch();
    error SameMorphoVault();
    error TokenNotAllowed();
    error CannotRemoveUsdc();
    error FeeNotAllowed();
    error InvalidFee();
    error SameToken();
    error DeadlinePassed();
    error InsufficientBalance();
    error InsufficientOutput();
    error WithdrawAddressNotAllowed();
    error BadArrayLength();
    error NotFound();
    error ProposalNotFound();
    error ProposalAlreadyExecuted();
    error ProposalIsCancelled();
    error ProposalExpired();
    error AlreadyApproved();
    error NotImplemented();

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner();
        _;
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param _usdc USDC token (must also appear in `_tokens`)
    /// @param _uniV3Router Uniswap V3 SwapRouter02
    /// @param _permit2 Permit2 (Phase 2)
    /// @param _universalRouter Uniswap UniversalRouter (Phase 2)
    /// @param _morphoVault MetaMorpho vault whose `asset()` is USDC
    /// @param _signers initial signers, at least `MIN_SIGNERS`
    /// @param _operators initial operators (may be empty), disjoint from `_signers`
    /// @param _withdrawAddresses initial withdraw whitelist
    /// @param _tokens initial token whitelist (must include `_usdc`)
    /// @param _fees initial Uniswap fee tiers (spec default: 500, 3000)
    constructor(
        address _usdc,
        address _uniV3Router,
        address _permit2,
        address _universalRouter,
        address _morphoVault,
        address[] memory _signers,
        address[] memory _operators,
        address[] memory _withdrawAddresses,
        address[] memory _tokens,
        uint24[] memory _fees
    ) {
        if (
            _usdc == address(0) || _uniV3Router == address(0) || _permit2 == address(0)
                || _universalRouter == address(0) || _morphoVault == address(0)
        ) revert ZeroAddress();
        if (IERC4626(_morphoVault).asset() != _usdc) revert VaultAssetMismatch();
        if (_signers.length < MIN_SIGNERS) revert TooFewSigners();

        usdc = _usdc;
        uniV3Router = _uniV3Router;
        permit2 = _permit2;
        universalRouter = _universalRouter;
        morphoVault = _morphoVault;

        // Signers first so the operator loop can enforce signer ∩ operator = ∅.
        for (uint256 i; i < _signers.length; ++i) {
            _addSigner(_signers[i]);
        }
        for (uint256 i; i < _operators.length; ++i) {
            _addOperator(_operators[i]);
        }
        for (uint256 i; i < _withdrawAddresses.length; ++i) {
            _addWithdrawAddress(_withdrawAddresses[i]);
        }
        for (uint256 i; i < _tokens.length; ++i) {
            _addToken(_tokens[i]);
        }
        if (!allowedToken[_usdc]) revert UsdcNotAllowed();
        for (uint256 i; i < _fees.length; ++i) {
            if (allowedFee[_fees[i]]) revert Duplicate();
            _setAllowedFee(_fees[i], true);
        }
    }

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

    /// @notice Swaps an exact amount of a whitelisted token held by the vault via Uniswap V3.
    ///         Used for both buys and sells. If `tokenOut` is USDC, the output is supplied to Morpho.
    /// @param tokenIn whitelisted token to sell
    /// @param tokenOut whitelisted token to buy
    /// @param fee whitelisted Uniswap V3 fee tier
    /// @param amountIn exact amount of `tokenIn` to sell
    /// @param amountOutMinimum minimum output (> 0); slippage is computed off-chain by the bot
    /// @param deadline unix timestamp after which the swap reverts
    /// @return amountOut amount of `tokenOut` received by the vault
    function swapExactInputV3(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 amountOut) {
        amountOut = _swapV3(tokenIn, tokenOut, fee, amountIn, amountOutMinimum, deadline);
    }

    /// @notice Buy order: withdraws exactly `usdcAmount` from Morpho, then swaps USDC -> `tokenOut`.
    ///         If the swap fails the whole tx reverts and the USDC stays in Morpho.
    /// @param tokenOut whitelisted token to buy (not USDC)
    /// @param fee whitelisted Uniswap V3 fee tier
    /// @param usdcAmount exact USDC amount to withdraw and sell
    /// @param amountOutMinimum minimum output (> 0)
    /// @param deadline unix timestamp after which the swap reverts
    /// @return amountOut amount of `tokenOut` received by the vault
    function withdrawAndSwapV3(
        address tokenOut,
        uint24 fee,
        uint256 usdcAmount,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 amountOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        // Validate cheap swap params before touching Morpho (same checks are repeated in _swapV3).
        if (tokenOut == usdc) revert SameToken();
        if (!allowedToken[tokenOut]) revert TokenNotAllowed();
        uint256 shares = _withdrawFromMorpho(usdcAmount);
        emit MorphoWithdrawn(usdcAmount, shares);
        amountOut = _swapV3(usdc, tokenOut, fee, usdcAmount, amountOutMinimum, deadline);
    }

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

    /// @notice Phase 2: Uniswap V4 swap via UniversalRouter + Permit2. Not implemented in Phase 1.
    /// @dev Always reverts. Parameter list mirrors the spec so the ABI shape is fixed; the real
    ///      implementation must build commands itself and require `hooks == address(0)`.
    function swapExactInputV4(address, address, uint24, int24, uint256, uint256, uint256)
        external
        view
        onlyOperator
        whenNotPaused
        returns (uint256)
    {
        revert NotImplemented();
    }

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

    /// @notice Returns all current signers.
    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    /// @notice Returns all whitelisted tokens.
    function getAllowedTokens() external view returns (address[] memory) {
        return _allowedTokenList;
    }

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

    /// @notice Approvals needed to execute: ≥ 50% of signers, rounded up. 2→1, 3→2, 4→2, 5→3.
    function getThreshold() public view returns (uint256) {
        return (signers.length + 1) / 2;
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

    function _addSigner(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        if (isSigner[a]) revert Duplicate();
        if (isOperator[a]) revert RoleConflict();
        isSigner[a] = true;
        signers.push(a);
        emit SignerAdded(a);
    }

    function _removeSigner(address a) internal {
        if (!isSigner[a]) revert NotFound();
        if (signers.length - 1 < MIN_SIGNERS) revert TooFewSigners();
        isSigner[a] = false;
        _removeFromArray(signers, a);
        emit SignerRemoved(a);
    }

    function _addOperator(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        if (isOperator[a]) revert Duplicate();
        if (isSigner[a]) revert RoleConflict();
        isOperator[a] = true;
        emit OperatorAdded(a);
    }

    function _removeOperator(address a) internal {
        if (!isOperator[a]) revert NotFound();
        isOperator[a] = false;
        emit OperatorRemoved(a);
    }

    function _addWithdrawAddress(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        if (isWithdrawAddress[a]) revert Duplicate();
        isWithdrawAddress[a] = true;
        emit WithdrawAddressAdded(a);
    }

    function _removeWithdrawAddress(address a) internal {
        if (!isWithdrawAddress[a]) revert NotFound();
        isWithdrawAddress[a] = false;
        emit WithdrawAddressRemoved(a);
    }

    function _addToken(address token) internal {
        if (token == address(0)) revert ZeroAddress();
        if (allowedToken[token]) revert Duplicate();
        allowedToken[token] = true;
        _allowedTokenList.push(token);
        emit TokenAllowed(token, true);
    }

    function _removeToken(address token) internal {
        if (token == usdc) revert CannotRemoveUsdc();
        if (!allowedToken[token]) revert NotFound();
        allowedToken[token] = false;
        _removeFromArray(_allowedTokenList, token);
        emit TokenAllowed(token, false);
    }

    function _setAllowedFee(uint24 fee, bool allowed) internal {
        if (fee == 0) revert InvalidFee();
        allowedFee[fee] = allowed;
        emit FeeAllowed(fee, allowed);
    }

    // ------------------------------------------------------------------
    // Internal: swaps & Morpho
    // ------------------------------------------------------------------

    function _swapV3(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (!allowedToken[tokenIn] || !allowedToken[tokenOut]) revert TokenNotAllowed();
        if (tokenIn == tokenOut) revert SameToken();
        if (amountIn == 0 || amountOutMinimum == 0) revert ZeroAmount();
        // SwapRouter02 on Base has no deadline field, so enforce it here.
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (!allowedFee[fee]) revert FeeNotAllowed();
        if (amountIn > IERC20(tokenIn).balanceOf(address(this))) revert InsufficientBalance();

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        // Atomic approval: exact amount -> swap -> reset to 0 (invariant 3).
        address router = uniV3Router;
        IERC20(tokenIn).forceApprove(router, amountIn);
        ISwapRouter02(router)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this), // hardcoded — never a parameter (invariant 2)
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(tokenIn).forceApprove(router, 0);

        // Measure what actually arrived instead of trusting the router's return value.
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < amountOutMinimum) revert InsufficientOutput();
        emit Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, SWAP_VERSION_V3);

        // Sell order: proceeds never sit idle.
        if (tokenOut == usdc) {
            uint256 shares = _supplyToMorpho(amountOut);
            emit MorphoDeposited(amountOut, shares);
        }
    }

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

    // ------------------------------------------------------------------
    // Private helpers
    // ------------------------------------------------------------------

    function _removeFromArray(address[] storage arr, address a) private {
        uint256 len = arr.length;
        for (uint256 i; i < len; ++i) {
            if (arr[i] == a) {
                arr[i] = arr[len - 1];
                arr.pop();
                return;
            }
        }
    }

    function _countValidApprovals(uint256 id) internal view returns (uint256 count) {
        uint256 len = signers.length;
        for (uint256 i; i < len; ++i) {
            if (hasApproved[id][signers[i]]) ++count;
        }
    }

    function _isExpired(Proposal storage p) internal view returns (bool) {
        return block.timestamp > uint256(p.createdAt) + PROPOSAL_TTL;
    }

    function _usdcInMorpho() internal view returns (uint256) {
        IERC4626 vault = IERC4626(morphoVault);
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }
}
