// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ICPAMMFactory} from "../Interfaces/ICPAMMFactory.sol";
import {ICPAMMHook} from "../Interfaces/ICPAMMHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UniswapV4Utils} from "../lib/UniswapV4Utils.sol";
import {CPAMMUtils} from "../lib/CPAMMUtils.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @title CPAMMLiquidityProvider
 * @notice Contract for managing liquidity provision in CPAMM (Constant Product AMM) pools
 * @dev This contract handles adding and removing liquidity from Uniswap V4-style pools with proper
 * slippage protection and optimal token amount calculations. It uses SafeERC20 for secure token transfers
 * and includes reentrancy protection.
 */
contract CPAMMLiquidityProvider is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CPAMMUtils for uint256;
    using CPAMMUtils for PoolId;

    // State variables
    ICPAMMFactory public immutable factory;
    IPoolManager public immutable poolManager;

    // Custom errors
    error DeadlineExpired(uint256 deadline);
    error InsufficientLiquidity(
        uint256 reserve0,
        uint256 reserve1,
        uint256 minLiquidity
    );
    error InvalidRecipient(address recipient);
    error PoolDoesNotExist(PoolId poolId);
    error SlippageExceeded(uint256 expected, uint256 actual);
    error InvalidTokens(address token0, address token1);
    error InsufficientAmount(uint256 actual, uint256 min);
    error ExcessiveInputAmount(uint256 desired, uint256 optimal);
    error InsufficientLiquidityMinted();

    bytes4 constant DeadlineExpiredSelector = bytes4(keccak256("DeadlineExpired(uint256)"));

    // Events
    event LiquidityAdded(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address to
    );

    event LiquidityRemoved(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address to
    );

    /**
     * @notice Initializes the liquidity provider contract
     * @param _factory Address of the CPAMM factory contract
     * @param _poolManager Address of the Uniswap V4 PoolManager
     */
    constructor(ICPAMMFactory _factory, IPoolManager _poolManager) {
        factory = _factory;
        poolManager = _poolManager;
    }

    /**
     * @notice Adds liquidity to a pool
     * @dev Calculates optimal token amounts and transfers tokens before adding liquidity
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @param amountADesired Desired amount of tokenA to add
     * @param amountBDesired Desired amount of tokenB to add
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param to Recipient address for the liquidity tokens
     * @param deadline Deadline timestamp for the transaction
     * @return amountA Actual amount of tokenA added
     * @return amountB Actual amount of tokenB added
     * @return liquidity Amount of liquidity tokens minted
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (to == address(0)) revert InvalidRecipient(to);

        // Split the logic into a separate internal function to reduce stack depth
        return
            _addLiquidityInternal(
                tokenA,
                tokenB,
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin,
                to
            );
    }

    /**
     * @dev Internal implementation of liquidity addition
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @param amountADesired Desired amount of tokenA to add
     * @param amountBDesired Desired amount of tokenB to add
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param to Recipient address for the liquidity tokens
     * @return amountA Actual amount of tokenA added
     * @return amountB Actual amount of tokenB added
     * @return liquidity Amount of liquidity tokens minted
     */
    function _addLiquidityInternal(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) internal returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Get or create pool and sort tokens
        (address token0, address token1) = UniswapV4Utils.sortTokens(
            tokenA,
            tokenB
        );
        PoolKey memory poolKey = _getPoolKey(token0, token1);

        // Calculate optimal amounts
        (amountA, amountB) = _calculateLiquidityAmounts(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );

        // Handle token transfers and liquidity addition
        return
            _processLiquidityAddition(
                tokenA,
                tokenB,
                token0,
                token1,
                amountA,
                amountB,
                poolKey,
                to
            );
    }

    /**
     * @dev Processes the actual liquidity addition to the pool
     * @param tokenA Original first token address (unsorted)
     * @param tokenB Original second token address (unsorted)
     * @param token0 Sorted first token address
     * @param token1 Sorted second token address
     * @param amountA Amount of tokenA to add
     * @param amountB Amount of tokenB to add
     * @param poolKey Pool key identifying the liquidity pool
     * @param to Recipient address for the liquidity tokens
     * @return finalAmountA Actual amount of tokenA added
     * @return finalAmountB Actual amount of tokenB added
     * @return liquidity Amount of liquidity tokens minted
     */
    function _processLiquidityAddition(
        address tokenA,
        address tokenB,
        address token0,
        address token1,
        uint256 amountA,
        uint256 amountB,
        PoolKey memory poolKey,
        address to
    )
        internal
        returns (uint256 finalAmountA, uint256 finalAmountB, uint256 liquidity)
    {
        // Sort the amounts according to token order
        uint256 amount0 = tokenA == token0 ? amountA : amountB;
        uint256 amount1 = tokenA == token0 ? amountB : amountA;

        // Transfer tokens to this contract
        if (amount0 > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        }

        // Calculate initial liquidity
        uint256 initialLiquidity = CPAMMUtils.calculateInitialLiquidity(amount0, amount1);
        
        // Revert if calculated liquidity is zero
        if (initialLiquidity == 0) {
            revert InsufficientLiquidityMinted();
        }

        // Modify liquidity through pool manager
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: UniswapV4Utils.MIN_TICK,
                tickUpper: UniswapV4Utils.MAX_TICK,
                liquidityDelta: int256(initialLiquidity),
                salt: bytes32(0)
            }),
            "" // Empty bytes calldata
        );

        // Convert delta.amount0() to positive uint256
        int256 amount = delta.amount0();
        liquidity = uint256(amount < 0 ? -amount : amount);
        
        // Additional check for final liquidity amount
        if (liquidity == 0) {
            revert InsufficientLiquidityMinted();
        }

        finalAmountA = amountA;
        finalAmountB = amountB;

        emit LiquidityAdded(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity,
            to
        );
        return (finalAmountA, finalAmountB, liquidity);
    }

    /**
     * @notice Removes liquidity from a pool
     * @dev Burns liquidity tokens and returns underlying assets to the recipient
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @param liquidity Amount of liquidity tokens to burn
     * @param amountAMin Minimum acceptable amount of tokenA to receive
     * @param amountBMin Minimum acceptable amount of tokenB to receive
     * @param to Recipient address for the withdrawn tokens
     * @param deadline Deadline timestamp for the transaction
     * @return amountA Actual amount of tokenA received
     * @return amountB Actual amount of tokenB received
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (to == address(0)) revert InvalidRecipient(to);

        PoolKey memory poolKey = _getPoolKey(tokenA, tokenB);
        (amountA, amountB) = _removeLiquidity(
            poolKey,
            liquidity,
            amountAMin,
            amountBMin,
            to
        );

        emit LiquidityRemoved(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity,
            to
        );

        return (amountA, amountB); // ✅ required
    }

    // Internal functions

    /**
     * @dev Calculates optimal token amounts for liquidity addition
     * @param token0 First token in the pair
     * @param token1 Second token in the pair
     * @param amount0Desired Desired amount of token0 to add
     * @param amount1Desired Desired amount of token1 to add
     * @param amount0Min Minimum acceptable amount of token0
     * @param amount1Min Minimum acceptable amount of token1
     * @return amount0 Optimal amount of token0 to add
     * @return amount1 Optimal amount of token1 to add
     */
    function _calculateLiquidityAmounts(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Get reserves
        (uint256 reserve0, uint256 reserve1) = _getReserves(token0, token1);

        // Calculate optimal amounts
        if (reserve0 == 0 && reserve1 == 0) {
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = (amount0Desired * reserve1) / reserve0;
            if (amount1Optimal <= amount1Desired) {
                if (amount1Optimal < amount1Min)
                    revert InsufficientAmount(amount1Optimal, amount1Min);
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                uint256 amount0Optimal = (amount1Desired * reserve0) / reserve1;
                if (amount0Optimal > amount0Desired)
                    revert ExcessiveInputAmount(amount0Desired, amount0Optimal);
                if (amount0Optimal < amount0Min)
                    revert InsufficientAmount(amount0Optimal, amount0Min);
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }
    }

    /**
     * @dev Retrieves the pool key for a given token pair
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @return PoolKey struct containing pool parameters
     */
    function _getPoolKey(
        address tokenA,
        address tokenB
    ) internal view returns (PoolKey memory) {
        (address token0, address token1) = UniswapV4Utils.sortTokens(
            tokenA,
            tokenB
        );
        // lookup the real fee & hook from the factory
        PoolId pid = factory.getPoolId(token0, token1);
        (, , uint24 fee, address hook) = factory.getPoolKey(pid);
        return
            PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: fee,
                tickSpacing: UniswapV4Utils.DEFAULT_TICK_SPACING,
                hooks: IHooks(hook)
            });
    }

    /**
     * @dev Internal implementation of liquidity removal
     * @param poolKey Pool key identifying the liquidity pool
     * @param liquidity Amount of liquidity tokens to burn
     * @param amountAMin Minimum acceptable amount of tokenA to receive
     * @param amountBMin Minimum acceptable amount of tokenB to receive
     * @param to Recipient address for the withdrawn tokens
     * @return amountA Actual amount of tokenA received
     * @return amountB Actual amount of tokenB received
     */
    function _removeLiquidity(
        PoolKey memory poolKey,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) internal returns (uint256 amountA, uint256 amountB) {
        // Ensure the pool exists
        PoolId poolId = poolKey.toId();
        if (!factory.poolExists(poolId)) revert PoolDoesNotExist(poolId);

        // Remove liquidity through pool manager
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: UniswapV4Utils.MIN_TICK,
                tickUpper: UniswapV4Utils.MAX_TICK,
                liquidityDelta: -int256(liquidity), // Negative for removal
                salt: bytes32(0)
            }),
            "" // Empty bytes calldata
        );

        // Convert delta amounts to uint256, handling negative values properly
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();

        amountA = uint256(amount0 > 0 ? amount0 : -amount0);
        amountB = uint256(amount1 > 0 ? amount1 : -amount1);

        // Check minimum amounts
        if (amountA < amountAMin)
            revert InsufficientAmount(amountA, amountAMin);
        if (amountB < amountBMin)
            revert InsufficientAmount(amountB, amountBMin);
    
        // Transfer tokens to recipient using Currency.unwrap() instead of toAddress()
        if (amountA > 0)
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(
                to,
                amountA
            );
        if (amountB > 0)
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(
                to,
                amountB
            );
    }
    
    /**
     * @dev Retrieves current reserves for a token pair
     * @param token0 First token in the pair
     * @param token1 Second token in the pair
     * @return reserve0 Reserve amount of token0
     * @return reserve1 Reserve amount of token1
     */
    function _getReserves(
        address token0,
        address token1
    ) internal view returns (uint256 reserve0, uint256 reserve1) {
        (address token0Sorted, address token1Sorted) = UniswapV4Utils.sortTokens(token0, token1);
        PoolId poolId = factory.getPoolId(token0Sorted, token1Sorted);
        if (!factory.poolExists(poolId)) revert PoolDoesNotExist(poolId);
        (reserve0, reserve1) = ICPAMMHook(factory.getHook(poolId)).getReserves(poolId);
    }
}
