// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title ICPAMMHook
 * @notice Interface for CPAMM (Constant Product Automated Market Maker) Hook in Uniswap V4
 * @dev This interface extends IHooks to provide custom AMM logic at various stages of pool operations.
 * It includes lifecycle hooks for pool initialization, liquidity modification, swaps, and donations.
 */
interface ICPAMMHook is IHooks {
    // Events
    event SlippageVerified(int256 amountSpecified, uint160 sqrtPriceLimitX96);
    event KValueUpdated(uint256 oldK, uint256 newK);
    event ReservesUpdated(PoolId indexed poolId, uint256 reserve0, uint256 reserve1);
    event FeeUpdated(PoolId indexed poolId, uint24 newFee);
    event PriceUpdate(PoolId indexed poolId, uint256 price, uint256 timestamp);

    // Shared errors
    error PoolDoesNotExist(PoolId poolId);
    error InvalidPoolManager(address poolManager);
    error InsufficientLiquidity(uint256 reserve0, uint256 reserve1, uint256 minLiquidity);
    error InvalidK(uint256 kLast, uint256 newK);
    error InvalidFee(uint256 fee, uint256 maxFee);

    // Core Hook Functions

    /**
     * @notice Hook called before pool initialization
     * @param sender The address initiating the initialization
     * @param key The pool key identifying the pool
     * @param sqrtPriceX96 The initial sqrt price as Q64.96
     * @return selector The function selector to validate hook call
     */
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    )
        external
        override
        returns (bytes4);

    /**
     * @notice Hook called after pool initialization
     * @param sender The address that initialized the pool
     * @param key The pool key identifying the pool
     * @param sqrtPriceX96 The initial sqrt price as Q64.96
     * @param tick The initial tick
     * @return selector The function selector to validate hook call
     */
    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    )
        external
        override
        returns (bytes4);

    /**
     * @notice Hook called before modifying a position
     * @param sender The address modifying the position
     * @param key The pool key identifying the pool
     * @param params Parameters for liquidity modification
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     */
    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        external
        returns (bytes4);

    /**
     * @notice Hook called after modifying a position
     * @param sender The address that modified the position
     * @param key The pool key identifying the pool
     * @param params Parameters used for liquidity modification
     * @param delta The resulting balance delta
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     */
    function afterModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    )
        external
        returns (bytes4);

    /**
     * @notice Hook called before a swap
     * @param sender The address initiating the swap
     * @param key The pool key identifying the pool
     * @param params Parameters for the swap
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     * @return swapDelta The requested swap delta
     * @return fee The fee to apply to the swap
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    )
        external
        returns (bytes4, BeforeSwapDelta, uint24);

    /**
     * @notice Hook called after a swap
     * @param sender The address that executed the swap
     * @param key The pool key identifying the pool
     * @param params Parameters used for the swap
     * @param delta The resulting balance delta
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     * @return protocolFee The protocol fee to collect
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    )
        external
        returns (bytes4, int128);

    /**
     * @notice Hook called before a donation
     * @param sender The address making the donation
     * @param key The pool key identifying the pool
     * @param amount0 The amount of token0 being donated
     * @param amount1 The amount of token1 being donated
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     */
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    )
        external
        override
        returns (bytes4);

    /**
     * @notice Hook called after a donation
     * @param sender The address that made the donation
     * @param key The pool key identifying the pool
     * @param amount0 The amount of token0 donated
     * @param amount1 The amount of token1 donated
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     */
    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    )
        external
        override
        returns (bytes4);

    // Liquidity-specific hooks

    /**
     * @notice Hook called before adding liquidity
     * @param sender The address adding liquidity
     * @param key The pool key identifying the pool
     * @param params Parameters for liquidity addition
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        external
        returns (bytes4);

    /**
     * @notice Hook called after adding liquidity
     * @param sender The address that added liquidity
     * @param key The pool key identifying the pool
     * @param params Parameters used for liquidity addition
     * @param delta The resulting balance delta
     * @param feesAccrued The fees accrued during the operation
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     * @return feeDelta The fee delta to apply
     */
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    )
        external
        returns (bytes4, BalanceDelta);

    /**
     * @notice Hook called before removing liquidity
     * @param sender The address removing liquidity
     * @param key The pool key identifying the pool
     * @param params Parameters for liquidity removal
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     */
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        external
        returns (bytes4);

    /**
     * @notice Hook called after removing liquidity
     * @param sender The address that removed liquidity
     * @param key The pool key identifying the pool
     * @param params Parameters used for liquidity removal
     * @param delta The resulting balance delta
     * @param feesAccrued The fees accrued during the operation
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate hook call
     * @return feeDelta The fee delta to apply
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    )
        external
        returns (bytes4, BalanceDelta);

    // View functions

    /**
     * @notice Get the current price and timestamp for a pool
     * @param poolId The ID of the pool
     * @return price The current price
     * @return timestamp The timestamp of the last price update
     */
    function getPrice(PoolId poolId) external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Get the current reserves for a pool
     * @param poolId The ID of the pool
     * @return reserve0 The reserve amount of token0
     * @return reserve1 The reserve amount of token1
     */
    function getReserves(PoolId poolId) external view returns (uint256 reserve0, uint256 reserve1);

    /**
     * @notice Get the bitmap of implemented hooks
     * @return A bitmap where each bit represents whether a specific hook is implemented
     */
    function getHooksCalls() external pure returns (uint24);

    /**
     * @notice Update the fee for a pool
     * @param pid The ID of the pool
     * @param newFee The new fee value (in basis points)
     * @return success Whether the fee update was successful
     */
    function updateFee(PoolId pid, uint24 newFee) external returns (bool);
}
