// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/**
 * @title ReserveTrackingHook
 * @notice A Uniswap V4 hook contract that tracks pool reserves for CPAMM functionality
 * @dev Implements IHooks interface to track liquidity changes, swaps, and donations
 * 
 * Key Features:
 * - Tracks token reserves for each pool
 * - Updates reserves after liquidity modifications, swaps, and donations
 * - Governance-controlled fee updates
 * - Provides reserve information to external contracts
 * 
 * Security Considerations:
 * - Only the PoolManager can call hook functions
 * - Only governance can update fees
 * - Governance address can only be set once
 */
contract ReserveTrackingHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;

    /// @notice The PoolManager contract
    IPoolManager public immutable poolManager;
    
    /// @notice The only address allowed to change fees
    address public governance;

    /// @notice Mapping of pool IDs to reserve amounts for token0
    mapping(PoolId => uint256) public reserve0;

    /// @notice Mapping of pool IDs to reserve amounts for token1
    mapping(PoolId => uint256) public reserve1;

    /// @notice Mapping of pool IDs to their current fees
    mapping(PoolId => uint24) public poolFee;

    error OnlyPoolManager();
    error OnlyGovernance();
    error GovernanceAlreadySet();
    error PoolNotInitialized(PoolId poolId);

    /**
     * @dev Modifier to restrict function access to only the PoolManager
     */
    modifier onlyByPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    /**
     * @dev Modifier to restrict function access to only governance
     */
    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    /**
     * @notice Constructs the ReserveTrackingHook contract
     * @param _poolManager The address of the PoolManager contract
     */
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager; 
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Governance entry–points
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the governance address (can only be called once)
     * @param _gov The address to set as governance
     * @dev Only callable once, by any account
     */
    function setGovernance(address _gov) external {
        if (governance != address(0)) revert GovernanceAlreadySet();
        governance = _gov;
    }

    /**
     * @notice Updates the fee for a specific pool
     * @param pid The pool ID to update
     * @param newFee The new fee value
     * @return Always returns true to prevent reverts in governance proposals
     * @dev Only callable by governance
     */
    function updateFee(PoolId pid, uint24 newFee) external onlyGovernance returns (bool) {
        poolFee[pid] = newFee;
        return true;
    }

    /**
     * @notice Gets the current fee for a pool
     * @param pid The pool ID to query
     * @return The current fee for the pool
     */
    function getFee(PoolId pid) external view returns (uint24) {
        return poolFee[pid];
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // IHooks implementation
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the hook permissions configuration
     * @return permissions The hook permissions structure
     * @dev Indicates which hook callbacks this contract implements
     */
    function getHookPermissions()
        external
        pure
        returns (Hooks.Permissions memory)
    {
        return
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
            });
    }

    /**
     * @notice Hook called before a pool is initialized
     * @param sender The address initiating the pool initialization
     * @param key The pool key defining the pool parameters
     * @param sqrtPriceX96 The initial square root price of the pool as Q64.96
     * @return selector The function selector to validate the hook call
     * @dev This implementation performs no operations and simply returns the selector
     */
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external pure override returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Hook called after a pool is initialized
     * @param sender The address that initialized the pool
     * @param key The pool key defining the pool parameters
     * @param sqrtPriceX96 The initial square root price of the pool
     * @param tick The initial tick of the pool
     * @return selector The function selector to validate the hook call
     * @dev This implementation performs no operations and simply returns the selector
     */
    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external pure override returns (bytes4) {
        return this.afterInitialize.selector;
    }

    /**
     * @notice Hook called before liquidity is added to a pool
     * @param sender The address adding liquidity
     * @param key The pool key identifying the pool
     * @param params The liquidity modification parameters
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @dev This implementation performs no operations and simply returns the selector
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external pure override returns (bytes4) {
        return this.beforeAddLiquidity.selector;
    }

    /**
     * @notice Called after liquidity is added to a pool
     * @param sender The address initiating the liquidity addition
     * @param key The pool key
     * @param params The liquidity modification parameters
     * @param delta The balance changes resulting from the operation
     * @param feesAccrued Any fees accrued during the operation
     * @param hookData Additional data passed to the hook
     * @return selector The function selector
     * @return deltaToReturn The delta to return (always zero)
     * @dev Only callable by PoolManager, updates reserves for the pool
     */
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        _updateReserves(poolId, delta);
        return (
            this.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    /**
     * @notice Hook called before liquidity is removed from a pool
     * @param sender The address removing liquidity
     * @param key The pool key identifying the pool
     * @param params The liquidity modification parameters
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @dev This implementation performs no operations and simply returns the selector
     */
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external pure override returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Hook called after liquidity is removed from a pool
     * @param sender The address that removed liquidity
     * @param key The pool key identifying the pool
     * @param params The liquidity modification parameters used
     * @param delta The change in token balances from the operation
     * @param feesAccrued Any fees accrued during the operation
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @return deltaToReturn The delta to return (always zero)
     * @dev Updates the pool reserves based on the liquidity removal
     * @notice Only callable by the PoolManager
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        _updateReserves(poolId, delta);
        return (
            this.afterRemoveLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    /**
     * @notice Hook called before a swap is executed
     * @param sender The address initiating the swap
     * @param key The pool key identifying the pool
     * @param params The swap parameters
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @return beforeSwapDelta The delta to apply before swap (always zero)
     * @return swapFee The swap fee (always zero)
     * @dev This implementation performs no operations and simply returns default values
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external pure override returns (bytes4, BeforeSwapDelta, uint24) {
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /**
     * @notice Hook called after a swap is executed
     * @param sender The address that initiated the swap
     * @param key The pool key identifying the pool
     * @param params The swap parameters used
     * @param delta The change in token balances from the swap
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @return afterSwapDelta The delta to apply after swap (always zero)
     * @dev Updates the pool reserves based on the swap results
     * @notice Only callable by the PoolManager
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        _updateReserves(poolId, delta);
        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Hook called before a donation is made to a pool
     * @param sender The address making the donation
     * @param key The pool key identifying the pool
     * @param amount0 The amount of token0 being donated
     * @param amount1 The amount of token1 being donated
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @dev This implementation performs no operations and simply returns the selector
     */
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external pure override returns (bytes4) {
        return this.beforeDonate.selector;
    }

    /**
     * @notice Hook called after a donation is made to a pool
     * @param sender The address that made the donation
     * @param key The pool key identifying the pool
     * @param amount0 The amount of token0 donated
     * @param amount1 The amount of token1 donated
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @dev Updates the pool reserves with the donated amounts
     * @notice Only callable by the PoolManager
     */
    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        reserve0[poolId] += amount0;
        reserve1[poolId] += amount1;
        return this.afterDonate.selector;
    }
   
    /**
     * @notice Gets the current reserves for a pool
     * @param poolId The pool ID to query
     * @return reserve0 The reserve amount of token0
     * @return reserve1 The reserve amount of token1
     */
    function getReserves(
        PoolId poolId
    ) external view returns (uint256, uint256) {
        return (reserve0[poolId], reserve1[poolId]);
    }

    /**
     * @dev Internal function to update reserves based on balance delta
     * @param poolId The pool ID to update
     * @param delta The balance changes to apply
     * @notice Handles both positive and negative deltas safely
     */
    function _updateReserves(PoolId poolId, BalanceDelta delta) internal {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            reserve0[poolId] += uint256(uint128(-amount0));
        } else if (amount0 > 0) {
            reserve0[poolId] = reserve0[poolId] > uint256(uint128(amount0))
                ? reserve0[poolId] - uint256(uint128(amount0))
                : 0;
        }

        if (amount1 < 0) {
            reserve1[poolId] += uint256(uint128(-amount1));
        } else if (amount1 > 0) {
            reserve1[poolId] = reserve1[poolId] > uint256(uint128(amount1))
                ? reserve1[poolId] - uint256(uint128(amount1))
                : 0;
        }
    }
}
