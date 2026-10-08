// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
        SetAllowedPool,
        Unpause,
        // Appended (not inserted) so existing enum values stay stable for off-chain tooling.
        ChangeUniV3Router,
        ChangePermit2,
        ChangeUniversalRouter,
        ChangeStableToken
    }

    /// @notice One whitelisted pool: the stable paired with `token`. `tickSpacing == V3_POOL` (0) means the
    ///         Uniswap V3 pool (stable, token, fee); `tickSpacing >= 1` means the hookless V4 pool
    ///         (stable, token, fee, tickSpacing).
    struct PoolConfig {
        address token;
        uint24 fee;
        int24 tickSpacing;
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
    /// @notice `version` value emitted in `Swapped` for Uniswap V4 swaps.
    uint8 public constant SWAP_VERSION_V4 = 4;
    /// @notice Uniswap V4 tick spacing bounds (v4-core TickMath.MIN/MAX_TICK_SPACING).
    int24 public constant MIN_TICK_SPACING = 1;
    int24 public constant MAX_TICK_SPACING = type(int16).max;
    /// @notice `PoolConfig.tickSpacing` value that marks a Uniswap V3 pool (V3 has no tick-spacing parameter;
    ///         V4 tick spacing is always >= 1, so 0 can never collide with a V4 pool).
    int24 public constant V3_POOL = 0;
    /// @notice Highest pool fee accepted (v4-core LPFeeLibrary.MAX_LP_FEE = 100%). Also rules out the V4
    ///         dynamic-fee flag (0x800000), which only hooked pools can use anyway.
    uint24 public constant MAX_POOL_FEE = 1_000_000;
    /// @notice Uniswap V4 currency id for native ETH. Whitelisting it in `allowedToken` enables native-ETH
    ///         V4 pools; V3 (SwapRouter02) cannot trade it.
    address public constant NATIVE = address(0);

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    /// @notice The single stablecoin: the only token that can be deposited, the only token supplied to Morpho,
    ///         and one side of every swap. Changed only via `ChangeStableToken`, which first sweeps every unit
    ///         of the old stable (idle + Morpho) out to a withdraw address.
    address public stableToken;
    /// @notice Current Morpho vault for `stableToken`. Changed only via a `ChangeMorphoVault` proposal.
    address public morphoVault;
    /// @notice Uniswap V3 SwapRouter02. Changed only via a `ChangeUniV3Router` proposal.
    /// @dev Safe to swap out: the vault never holds a standing approval to the old router (invariant 3).
    address public uniV3Router;
    /// @notice Permit2 (V4 swaps). Changed only via a `ChangePermit2` proposal.
    address public permit2;
    /// @notice Uniswap UniversalRouter (V4 swaps). Changed only via a `ChangeUniversalRouter` proposal.
    address public universalRouter;

    mapping(address => bool) public isSigner;
    address[] public signers;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isWithdrawAddress;

    /// @notice Tradable tokens (bought / sold against `stableToken`, held idle in the vault — never sent to
    ///         Morpho). Never contains `stableToken`. May contain `NATIVE` (address(0)) for V4 native-ETH pools.
    mapping(address => bool) public allowedToken;
    /// @dev Mirror of `allowedToken` so views can list whitelisted balances without ever
    ///      touching a non-whitelisted (possibly malicious) token.
    address[] internal _allowedTokenList;
    /// @notice Pools the operator may swap through: `allowedPool[token][fee][tickSpacing]`
    ///         (`tickSpacing == V3_POOL` = V3 pool, otherwise hookless V4 pool). The token, fee and tick spacing
    ///         are whitelisted together as one entry, so the operator can never combine them into a pool the
    ///         signers did not pick — e.g. a fresh, attacker-seeded pool with an unused fee / spacing combo.
    /// @dev No on-chain list (contract size limit): the full set is rebuilt off-chain from `PoolAllowed` events.
    mapping(address => mapping(uint24 => mapping(int24 => bool))) public allowedPool;

    bool public paused;
    /// @dev True only while `swapExactInputV4` is waiting for native ETH output; `receive()` rejects ETH
    ///      at every other moment.
    bool internal _expectingNative;

    /// @dev Raw storage; `getProposal(id)` adds live vote count, threshold and expiry.
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasApproved;
    mapping(uint256 => mapping(address => bool)) public hasRejected;
    uint256 public proposalCount;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Deposited(address indexed from, uint256 amount, uint256 shares);
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
    event ProposalRejected(uint256 indexed id, address indexed signer);
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
    event UniV3RouterChanged(address oldRouter, address newRouter);
    event Permit2Changed(address oldPermit2, address newPermit2);
    event UniversalRouterChanged(address oldRouter, address newRouter);
    event StableTokenChanged(
        address oldStable, address newStable, address oldMorphoVault, address newMorphoVault, uint256 sweptAmount
    );
    event TokenAllowed(address token, bool allowed);
    event PoolAllowed(address token, uint24 fee, int24 tickSpacing, bool allowed);
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
    error StableNotTradable();
    error SameMorphoVault();
    error SameAddress();
    error TokenNotAllowed();
    error NativeNotSupported();
    error NativeTransferFailed();
    error UnexpectedNative();
    error PoolNotAllowed();
    error InvalidFee();
    error InvalidTickSpacing();
    error AmountTooLarge();
    error ExcessiveInput();
    error PairNotAllowed();
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
    error AlreadyVoted();

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
    /// @param _stableToken the single stablecoin (e.g. USDC)
    /// @param _uniV3Router Uniswap V3 SwapRouter02
    /// @param _permit2 Permit2 (V4 swaps)
    /// @param _universalRouter Uniswap UniversalRouter (V4 swaps)
    /// @param _morphoVault Morpho vault (ERC-4626) for `_stableToken`, chosen by the owner
    constructor(
        address _stableToken,
        address _uniV3Router,
        address _permit2,
        address _universalRouter,
        address _morphoVault
    ) {
        if (
            _stableToken == address(0) || _uniV3Router == address(0) || _permit2 == address(0)
                || _universalRouter == address(0) || _morphoVault == address(0)
        ) revert ZeroAddress();

        stableToken = _stableToken;
        uniV3Router = _uniV3Router;
        permit2 = _permit2;
        universalRouter = _universalRouter;
        morphoVault = _morphoVault;
    }
}
