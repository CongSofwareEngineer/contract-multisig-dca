// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DCAVaultStorage
/// @notice Shared base of DCAVault: types, constants, immutables, state, events, errors, modifiers.
/// @dev Every state variable lives here (and only here) so the storage layout is defined in one place.
///      The other `DCAVault*` modules only add logic on top of this.
abstract contract DCAVaultStorage is ReentrancyGuard {
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
    address[] internal _allowedTokenList;
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

    /// @dev Sets protocol addresses only; roles / whitelists are seeded by `DCAVault`'s constructor.
    /// @param _usdc USDC token
    /// @param _uniV3Router Uniswap V3 SwapRouter02
    /// @param _permit2 Permit2 (Phase 2)
    /// @param _universalRouter Uniswap UniversalRouter (Phase 2)
    /// @param _morphoVault MetaMorpho vault whose `asset()` is USDC
    constructor(address _usdc, address _uniV3Router, address _permit2, address _universalRouter, address _morphoVault) {
        if (
            _usdc == address(0) || _uniV3Router == address(0) || _permit2 == address(0)
                || _universalRouter == address(0) || _morphoVault == address(0)
        ) revert ZeroAddress();
        if (IERC4626(_morphoVault).asset() != _usdc) revert VaultAssetMismatch();

        usdc = _usdc;
        uniV3Router = _uniV3Router;
        permit2 = _permit2;
        universalRouter = _universalRouter;
        morphoVault = _morphoVault;
    }
}
