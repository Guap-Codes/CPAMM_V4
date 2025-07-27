// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ICPAMMFactory
 * @notice Interface for the CPAMM (Constant Product Automated Market Maker) Factory contract
 * @dev This interface defines the core functionality for creating and managing CPAMM pools in a Uniswap V4 environment.
 * It handles pool creation, hook management, and provides view functions for pool information.
 */
interface ICPAMMFactory {
    // Events
    event PoolCreated(
        PoolId indexed poolId,
        address indexed token0,
        address indexed token1,
        uint24 fee,
        address hook
    );
    event HookRegistered(address indexed hook, bool valid);
    event EmergencyAction(string action, address indexed triggeredBy);
    event PairCreated(PoolId indexed poolId, address pair);

    // Core functions

    /**
     * @notice Creates a new CPAMM pool
     * @dev The tokens may be passed in either order (tokenA/tokenB)
     * @param tokenA The first token in the pair
     * @param tokenB The second token in the pair
     * @param fee The fee tier for the pool (in basis points)
     * @param sqrtPriceX96 The initial square root price of the pool as a Q64.96 value
     * @return poolId The ID of the newly created pool
     * @return hook The address of the hook contract associated with this pool
     */
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (PoolId poolId, address hook);

    // View functions

    /**
     * @notice Checks if a hook is valid and registered
     * @param hook The address of the hook contract to check
     * @return True if the hook is valid, false otherwise
     */
    function isHookValid(address hook) external view returns (bool);

    /**
     * @notice Checks if a pool exists
     * @param poolId The ID of the pool to check
     * @return True if the pool exists, false otherwise
     */
    function poolExists(PoolId poolId) external view returns (bool);

    /**
     * @notice Gets the hook address associated with a pool
     * @param poolId The ID of the pool
     * @return The address of the hook contract
     */
    function getHook(PoolId poolId) external view returns (address);

    /**
     * @notice Gets the full pool key information for a given pool ID
     * @param poolId The ID of the pool
     * @return token0 The first token in the pool pair
     * @return token1 The second token in the pool pair
     * @return fee The fee tier for the pool (in basis points)
     * @return hook The address of the hook contract
     */
    function getPoolKey(
        PoolId poolId
    )
        external
        view
        returns (address token0, address token1, uint24 fee, address hook);

    /**
     * @notice Validates whether a hook meets all requirements
     * @param hook The address of the hook contract to validate
     * @return True if the hook is valid, false otherwise
     */
    function validateHook(address hook) external view returns (bool);

    /**
     * @notice Validates whether a pool meets all requirements
     * @param poolId The address of the pool contract to validate
     * @return True if the pool is valid, false otherwise
     */
    function validatePool(PoolId poolId) external view returns (bool);

    // Management functions

    /**
     * @notice Registers a new hook contract
     * @dev Only callable by authorized addresses
     * @param hook The address of the hook contract to register
     */
    function registerHook(address hook) external;

    // Pair information functions

    /**
     * @notice Gets the pair address for a given pool ID
     * @param pid The ID of the pool
     * @return pair The address of the pair contract
     */
    function getPair(PoolId pid) external view returns (address pair);

    /**
     * @notice Gets the pair address for a given token pair
     * @param tokenA The first token in the pair
     * @param tokenB The second token in the pair
     * @return pair The address of the pair contract
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    /**
     * @notice Gets the pool ID for a given token pair
     * @param token0 The first token in the pair
     * @param token1 The second token in the pair
     * @return The ID of the pool for this token pair
     */
    function getPoolId(
        address token0,
        address token1
    ) external view returns (PoolId);
}
