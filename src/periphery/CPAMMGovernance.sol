// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICPAMMFactory} from "../Interfaces/ICPAMMFactory.sol";
import {ICPAMMHook} from "../Interfaces/ICPAMMHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CPAMMUtils} from "../lib/CPAMMUtils.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title CPAMMGovernance
 * @notice Governance contract for managing fee updates and other parameters in CPAMM pools
 * @dev This contract combines Ownable, Pausable, ReentrancyGuard, and AccessControl for comprehensive management.
 * It allows for proposal-based fee changes with configurable delays and proper access control.
 */
contract CPAMMGovernance is Ownable, Pausable, ReentrancyGuard, AccessControl {
    using CPAMMUtils for PoolId;

    // State variables
    ICPAMMFactory public immutable factory;
    IPoolManager public immutable poolManager;
    uint256 public constant MAX_FEE = CPAMMUtils.MAX_FEE;
    uint256 public constant MIN_DELAY = 1 days;
    uint256 public constant MAX_DELAY = 30 days;

    // Proposal states
    /**
     * @dev Enum representing the various states a proposal can be in
     */
    enum ProposalState { Pending, Active, Executed, Cancelled }
    
    /**
     * @dev Struct representing a governance proposal
     * @param id Unique identifier for the proposal
     * @param proposer Address that created the proposal
     * @param poolId The PoolId this proposal affects
     * @param newFee Proposed new fee value (in basis points)
     * @param delay Time delay required before execution
     * @param createdAt Timestamp when proposal was created
     * @param state Current state of the proposal
     */
    struct Proposal {
        uint256 id;
        address proposer;
        PoolId poolId;
        uint24 newFee;
        uint256 delay;
        uint256 createdAt;
        ProposalState state;
    }

    // Storage
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    mapping(PoolId => uint256) public lastFeeUpdate;
    mapping(address => bool) public isAuthorized;

    // Events
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, PoolId indexed poolId, uint24 newFee);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event AuthorizationChanged(address indexed account, bool isAuthorized);
    event EmergencyAction(string action, address indexed triggeredBy);

    // Errors
    error InvalidFee(uint24 fee, uint24 maxFee);
    error InvalidDelay(uint256 delay, uint256 minDelay, uint256 maxDelay);
    error InvalidProposal(uint256 proposalId);
    error InvalidPoolId(PoolId poolId);
    error UnauthorizedCaller(/*address caller*/);
    error ProposalNotActive(uint256 proposalId);
    error DelayNotElapsed(uint256 current, uint256 required);
    error InvalidFactory(address factory);

    // Role definitions
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /**
     * @notice Initializes the governance contract
     * @param _poolManager Address of the Uniswap V4 PoolManager
     * @param _factory Address of the CPAMM factory contract
     */
    constructor(
        IPoolManager _poolManager,
        address _factory
    ) Ownable(msg.sender) {
        poolManager = _poolManager;
        factory = ICPAMMFactory(_factory);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
    }

    // Core functions

    /**
     * @notice Creates a new fee change proposal
     * @dev Only callable by owner, PROPOSER_ROLE holders, or authorized addresses
     * @param poolId The PoolId to modify
     * @param newFee Proposed new fee value (must be <= MAX_FEE)
     * @param delay Execution delay (must be between MIN_DELAY and MAX_DELAY)
     * @return proposalId The ID of the newly created proposal
     */
    function createProposal(PoolId poolId, uint24 newFee, uint256 delay) 
        external 
        whenNotPaused 
        returns (uint256)
    {       
        // Allow owner to create proposals without additional roles
        if (msg.sender != owner() && !hasRole(PROPOSER_ROLE, msg.sender) && !isAuthorized[msg.sender]) 
            revert UnauthorizedCaller(/*msg.sender*/);
        if (!factory.validatePool(poolId)) revert InvalidPoolId(poolId);
        if (newFee > MAX_FEE) revert InvalidFee(newFee, uint24(MAX_FEE));
        if (delay < MIN_DELAY || delay > MAX_DELAY) revert InvalidDelay(delay, MIN_DELAY, MAX_DELAY);

        uint256 proposalId = ++proposalCount;
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            poolId: poolId,
            newFee: newFee,
            delay: delay,
            createdAt: block.timestamp,
            state: ProposalState.Active
        });

        emit ProposalCreated(proposalId, msg.sender, poolId, newFee);
        return proposalId;
    }

    /**
     * @notice Executes an approved proposal after its delay period
     * @dev Uses nonReentrant modifier to prevent reentrancy attacks
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Active) revert ProposalNotActive(proposalId);
        if (block.timestamp < proposal.createdAt + proposal.delay) {
            revert DelayNotElapsed(block.timestamp, proposal.createdAt + proposal.delay);
        }

        ICPAMMHook hook = ICPAMMHook(factory.getHook(proposal.poolId));
        bool success = hook.updateFee(proposal.poolId, proposal.newFee);
        require(success, "Fee update failed");
        
        proposal.state = ProposalState.Executed;
        lastFeeUpdate[proposal.poolId] = block.timestamp;

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancels an active proposal
     * @dev Only callable by proposal creator or authorized addresses
     * @param proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Active) revert ProposalNotActive(proposalId);
        if (msg.sender != proposal.proposer && !isAuthorized[msg.sender]) revert UnauthorizedCaller(/*msg.sender*/);
        
        proposal.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    // Admin functions

    /**
     * @notice Sets authorization status for an address
     * @dev Only callable by contract owner
     * @param account Address to modify authorization for
     * @param authorized New authorization status
     */
    function setAuthorization(address account, bool authorized) external onlyOwner {
        isAuthorized[account] = authorized;
        emit AuthorizationChanged(account, authorized);
    }

    /**
     * @notice Pauses all governance operations
     * @dev Only callable by contract owner
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyAction("pause", msg.sender);
    }

    /**
     * @notice Unpauses governance operations
     * @dev Only callable by contract owner
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyAction("unpause", msg.sender);
    }

    // View functions

    /**
     * @notice Retrieves proposal details
     * @param proposalId ID of the proposal to query
     * @return The complete Proposal struct
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Checks if a proposal is in Active state
     * @param proposalId ID of the proposal to check
     * @return True if proposal is active, false otherwise
     */
    function isProposalActive(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].state == ProposalState.Active;
    }

    // Role management functions

    /**
     * @notice Grants a role to an account
     * @dev Only callable by contract owner
     * @param role Role identifier to grant
     * @param account Address to grant the role to
     */
    function grantRole(bytes32 role, address account) public override onlyOwner {
        _grantRole(role, account);
    }

    /**
     * @notice Revokes a role from an account
     * @dev Only callable by contract owner
     * @param role Role identifier to revoke
     * @param account Address to revoke the role from
     */
    function revokeRole(bytes32 role, address account) public override onlyOwner {
        _revokeRole(role, account);
    }

    /**
     * @notice Checks if an account has a specific role
     * @param role Role identifier to check
     * @param account Address to check
     * @return True if account has the role, false otherwise
     */
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return super.hasRole(role, account);
    }
}