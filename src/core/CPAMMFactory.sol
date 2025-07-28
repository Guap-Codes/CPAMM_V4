// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { UniswapV4Utils } from "../lib/UniswapV4Utils.sol";
import { CPAMMUtils } from "../lib/CPAMMUtils.sol";
import { ICPAMMFactory } from "../Interfaces/ICPAMMFactory.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { ReserveTrackingHook } from "../core/ReserveTrackingHook.sol";
import { UniswapV4Pair } from "../core/UniswapV4Pair.sol";

/**
 * @title CPAMMFactory
 * @dev Factory contract for creating and managing concentrated liquidity pools in the CPAMM protocol
 * @notice This contract handles pool creation, pair tracking, and hook validation for all CPAMM-based markets.
 *
 * Key Responsibilities:
 * - Create new Uniswap V4-style pools with a predefined hook
 * - Deploy LP token contracts (`UniswapV4Pair`) per pool
 * - Validate hook and pool configurations
 * - Pause/unpause factory in emergencies
 *
 * Security Considerations:
 * - ReentrancyGuard protects against nested call exploits
 * - Only the owner can pause or unpause operations
 * - All hooks must pass strict permission validation
 */
contract CPAMMFactory is ICPAMMFactory, Ownable, Pausable, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using UniswapV4Utils for uint160;
    using UniswapV4Utils for address;
    using CPAMMUtils for uint256;
    using CPAMMUtils for PoolKey;
    using CPAMMUtils for PoolId;
    using UniswapV4Utils for uint24;

    // Constants
    /// @dev Default LP fee (30 bps)
    uint16 public constant DEFAULT_FEE = 3000; // 0.3% default fee

    /// @dev Default tick spacing for pools
    int24 public constant DEFAULT_TICK_SPACING = UniswapV4Utils.DEFAULT_TICK_SPACING;

    /// @dev Default slippage tolerance (0.5%)
    uint256 public constant DEFAULT_SLIPPAGE = 50; // 0.5%

    /// @dev Default protocol fee (5 bps)
    uint24 public constant DEFAULT_PROTOCOL_FEE = 500; // 0.05%

    // Custom errors
    error IdenticalAddresses(address token);
    error ZeroAddress();
    error InvalidFee(uint24 fee);
    error InvalidHook(address hook);
    error PoolAlreadyExists(PoolId poolId);
    error HookAddressNotValid(address hook);

    // State variables
    /// @notice The Uniswap V4 PoolManager responsible for pool deployment
    IPoolManager public immutable poolManager;

    /// @notice Governance address with protocol configuration privileges
    address public immutable governance;

    /// @notice The reserve-tracking hook used for CPAMM
    ReserveTrackingHook public immutable reserveHook;

    /// @notice Reference to the router contract
    address public immutable router;

    /// @dev Mapping from PoolId to pool existence flag
    mapping(PoolId => bool) public poolExistsMap;

    /// @dev Maps token pairs to their PoolId (sorted order)
    mapping(address => mapping(address => PoolId)) private tokenPairToPoolId;

    /// @dev Maps PoolId to its associated PoolKey
    mapping(PoolId => PoolKey) private poolKeysMap;

    /// @dev Maps PoolId to the deployed LP token contract address
    mapping(PoolId => address) private _pairs;

    /**
     * @dev Constructor to initialize the factory with key dependencies
     * @param _poolManager Address of the Uniswap V4 PoolManager
     * @param _governance Address of the protocol governance
     * @param _reserveHook Address of the pre-deployed ReserveTrackingHook
     * @param _owner Address of the factory contract owner
     * @param _router Address of the CPAMM router
     */
    constructor(
        IPoolManager _poolManager,
        address _governance,
        address _reserveHook,
        address _owner,
        address _router // New: Accept router address
    )
        Ownable(_owner)
    {
        poolManager = _poolManager;
        governance = _governance;
        reserveHook = ReserveTrackingHook(_reserveHook);
        router = _router; // New: Initialize router
    }

    /**
     * @dev Registers a hook contract for use with pools
     * @param hook Address of the hook contract to register
     * @notice Only the reserveHook can be registered
     * @notice Only callable by the owner
     * @inheritdoc ICPAMMFactory
     */
    function registerHook(address hook) external override onlyOwner {
        require(hook != address(0), "CPAMMFactory: zero hook");
        require(hook == address(reserveHook), "CPAMMFactory: only reserveHook allowed");
        emit HookRegistered(hook, true);
    }

    /**
     * @dev Creates a new concentrated liquidity pool
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @param fee The fee for swaps in basis points
     * @param sqrtPriceX96 The initial square root price of the pool
     * @return poolId The ID of the created pool
     * @return hookAddr Address of the hook contract used
     * @notice Non-reentrant and pausable
     * @notice Tokens are automatically sorted by address
     * @inheritdoc ICPAMMFactory
     */
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint160 sqrtPriceX96
    )
        external
        override
        nonReentrant
        whenNotPaused
        returns (PoolId poolId, address hookAddr)
    {
        if (tokenA == tokenB) revert IdenticalAddresses(tokenA);
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (fee > CPAMMUtils.MAX_FEE) revert InvalidFee(fee);

        // Sort tokens
        (address token0, address token1) = UniswapV4Utils.sortTokens(tokenA, tokenB);

        // Use the pre-deployed ReserveTrackingHook
        hookAddr = address(reserveHook);
        if (hookAddr == address(0)) revert InvalidHook(hookAddr);

        // Validate hook permissions
        Hooks.validateHookPermissions(
            IHooks(hookAddr),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: true,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );

        // Form pool key with ReserveTrackingHook
        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = pk.toId();
        // idempotent: if someone has already created this pool, just return it
        if (poolExistsMap[poolId]) {
            return (poolId, hookAddr);
        }

        // Register pool
        poolExistsMap[poolId] = true;
        poolKeysMap[poolId] = pk;
        tokenPairToPoolId[token0][token1] = poolId;

        // Initialize pool in PoolManager
        poolManager.initialize(pk, sqrtPriceX96);

        // deploy the LP‑token contract for this pool ---
        UniswapV4Pair pair = new UniswapV4Pair(poolManager, pk, address(this), router);
        _pairs[poolId] = address(pair);
        emit PairCreated(poolId, address(pair));

        emit PoolCreated(poolId, token0, token1, fee, hookAddr);
        return (poolId, hookAddr);
    }

    // ===================== VIEW FUNCTIONS =====================

    /**
     * @dev Gets the LP token address for a pool
     * @param pid The pool ID
     * @return Address of the LP token contract
     * @inheritdoc ICPAMMFactory
     */
    function getPair(PoolId pid) public view override returns (address) {
        return _pairs[pid];
    }

    /**
     * @dev Gets the LP token address for a token pair
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @return Address of the LP token contract
     * @notice Tokens are automatically sorted by address
     * @inheritdoc ICPAMMFactory
     */
    function getPair(address tokenA, address tokenB) public view override returns (address) {
        (address t0, address t1) = UniswapV4Utils.sortTokens(tokenA, tokenB);
        PoolKey memory pk = poolKeysMap[PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(reserveHook))
        }).toId()];
        return _pairs[pk.toId()];
    }

    /**
     * @dev Gets the pool ID for a token pair
     * @param token0 First token in the pair
     * @param token1 Second token in the pair
     * @return The pool ID
     * @notice Tokens must be passed in sorted order
     * @inheritdoc ICPAMMFactory
     */
    function getPoolId(address token0, address token1) external view override returns (PoolId) {
        (address t0, address t1) = UniswapV4Utils.sortTokens(token0, token1);
        return tokenPairToPoolId[t0][t1];
    }

    /**
     * @dev Gets the pool key details
     * @param pid The pool ID
     * @return token0 First token in the pair
     * @return token1 Second token in the pair
     * @return fee The pool fee
     * @return hook The hook address
     * @inheritdoc ICPAMMFactory
     */
    function getPoolKey(PoolId pid)
        external
        view
        override
        returns (address token0, address token1, uint24 fee, address hook)
    {
        require(poolExistsMap[pid], "CPAMMFactory: no pool");
        PoolKey memory k = poolKeysMap[pid];
        return (Currency.unwrap(k.currency0), Currency.unwrap(k.currency1), k.fee, address(k.hooks));
    }

    /**
     * @dev Validates if a hook address is the reserveHook
     * @param hook The hook address to validate
     * @return True if valid, false otherwise
     * @inheritdoc ICPAMMFactory
     */
    function validateHook(address hook) public view override returns (bool) {
        return hook == address(reserveHook);
    }

    /**
     * @dev Gets the hook address for a pool
     * @param pid The pool ID
     * @return The hook address
     * @inheritdoc ICPAMMFactory
     */
    function getHook(PoolId pid) external view override returns (address) {
        require(poolExistsMap[pid], "CPAMMFactory: no pool");
        return address(reserveHook);
    }

    /**
     * @dev Checks if a pool exists
     * @param pid The pool ID
     * @return True if pool exists, false otherwise
     * @inheritdoc ICPAMMFactory
     */
    function poolExists(PoolId pid) external view override returns (bool) {
        return poolExistsMap[pid];
    }

    /**
     * @dev Checks if a hook address is valid
     * @param h The hook address to check
     * @return True if valid, false otherwise
     * @inheritdoc ICPAMMFactory
     */
    function isHookValid(address h) external view override returns (bool) {
        return h == address(reserveHook);
    }

    /**
     * @dev Validates all pool parameters
     * @param pid The pool ID
     * @return True if pool is valid, false otherwise
     * @inheritdoc ICPAMMFactory
     */
    function validatePool(PoolId pid) external view override returns (bool) {
        if (!poolExistsMap[pid]) return false;
        PoolKey memory k = poolKeysMap[pid];
        address h = address(k.hooks);
        if (h != address(reserveHook)) return false;
        address t0 = Currency.unwrap(k.currency0);
        address t1 = Currency.unwrap(k.currency1);
        if (t0 == address(0) || t1 == address(0) || t0 == t1) return false;
        if (k.fee > CPAMMUtils.MAX_FEE) return false;
        return true;
    }

    /**
     * @notice Emergency pause the factory to disable pool creation
     * @dev Only callable by the owner
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyAction("pause", msg.sender);
    }

    /**
     * @notice Emergency unpause the factory
     * @dev Only callable by the owner
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyAction("unpause", msg.sender);
    }
}
