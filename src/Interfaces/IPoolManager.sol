// SPDX‑License‑Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title IPoolManager
 * @notice Interface for the Uniswap V4 Pool Manager contract
 * @dev This interface defines the core functionality for pool management in Uniswap V4,
 * including pool initialization, liquidity modification, and swap operations.
 */
interface IPoolManager {
    /**
     * @notice Initializes a new pool with the given parameters
     * @param key The PoolKey struct containing pool parameters
     * @param sqrtPriceX96 The initial square root price of the pool as a Q64.96 value
     * @return poolId The ID of the newly created pool
     */
    function initialize(
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external returns (bytes32 poolId);

    /**
     * @dev Parameters for modifying liquidity in a pool
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidityDelta The amount of liquidity to add or remove
     * @param salt A salt value for uniqueness (used in pool creation)
     */
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    /**
     * @notice Modifies liquidity in an existing pool
     * @param key The PoolKey struct identifying the pool
     * @param params The ModifyLiquidityParams struct containing liquidity modification details
     * @param data Additional data to pass to the callback
     * @return callerDelta The balance delta for the caller
     * @return feesAccrued The fees accrued during the operation
     */
    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata data
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    /**
     * @dev Parameters for executing a swap in a pool
     * @param zeroForOne The direction of the swap (true for token0 to token1, false for reverse)
     * @param amountSpecified The amount of the swap (positive for exact input, negative for exact output)
     * @param sqrtPriceLimitX96 The price limit for the swap as a Q64.96 value
     */
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice Executes a swap in the specified pool
     * @param key The PoolKey struct identifying the pool
     * @param params The SwapParams struct containing swap details
     * @param data Additional data to pass to the callback
     * @return swapDelta The balance delta resulting from the swap
     */
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata data
    ) external returns (BalanceDelta swapDelta);

    /**
     * @notice Retrieves the address of a pool given its key
     * @param key The PoolKey struct identifying the pool
     * @return pool The address of the requested pool
     */
    function pools(PoolKey calldata key) external view returns (address pool);
}
