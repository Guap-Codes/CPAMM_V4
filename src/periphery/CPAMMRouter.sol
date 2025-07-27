// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ICPAMMFactory} from "../Interfaces/ICPAMMFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UniswapV4Utils} from "../lib/UniswapV4Utils.sol";
import {CPAMMUtils} from "../lib/CPAMMUtils.sol";
import {ICPAMMHook} from "../Interfaces/ICPAMMHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {UniswapV4Pair} from "../core/UniswapV4Pair.sol";
import {MockPoolManager} from "../../test/mocks/MockPoolManager.sol";

/**
 * @title CPAMMRouter
 * @notice Router contract for interacting with CPAMM (Constant Product AMM) pools
 * @dev Provides functionality for adding/removing liquidity and swapping tokens with
 * built-in slippage protection and deadline enforcement. Uses Uniswap V4 PoolManager
 * for core operations.
 */
contract CPAMMRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using UniswapV4Utils for uint160;
    using CPAMMUtils for uint256;

    // State variables
    ICPAMMFactory public factory;
    IPoolManager public immutable poolManager;

    // Custom errors
    error DeadlineExpired(uint256 deadline);
    error InsufficientOutputAmount(uint256 expected, uint256 actual);
    error ExcessiveInputAmount(uint256 expected, uint256 actual);
    error InvalidPath();
    error PoolNotFound(PoolId poolId);
    error InsufficientLiquidity(
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 minLiquidity
    );
    error InvalidSwapAmount(/*uint256 amount0Out, uint256 amount1Out*/);
    error InvalidRecipient(address recipient);
    error PoolDoesNotExist(PoolId poolId);
    error InsufficientAmount(uint256 amount, uint256 minAmount);

    // Events
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

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
     * @notice Initializes the router contract
     * @param _poolManager Address of the Uniswap V4 PoolManager
     */
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /**
     * @notice Sets the factory contract address (can only be set once)
     * @dev This must be called after factory deployment
     * @param _factory Address of the CPAMM factory contract
     */
    function setFactory(address _factory) external {
        require(address(factory) == address(0), "factory already set");
        require(_factory != address(0),    "zero factory");
        factory = ICPAMMFactory(_factory);
    }

    // Core functions

    /**
     * @notice Adds liquidity to a pool
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
        return
            _addLiquidityInternal(
                LiquidityParams({
                    tokenA: tokenA,
                    tokenB: tokenB,
                    amountADesired: amountADesired,
                    amountBDesired: amountBDesired,
                    amountAMin: amountAMin,
                    amountBMin: amountBMin,
                    to: to
                })
            );
    }

    /**
     * @notice Removes liquidity from a pool
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

        (address token0, address token1) = UniswapV4Utils.sortTokens(tokenA, tokenB);
        PoolId poolId = factory.getPoolId(token0, token1);
        if (!factory.poolExists(poolId)) revert PoolDoesNotExist(poolId);

        PoolKey memory poolKey = _getPoolKey(token0, token1);
        address pairAddr = factory.getPair(poolId);
        UniswapV4Pair pair = UniswapV4Pair(pairAddr);

        // Transfer LP tokens from user to pair
        IERC20(pairAddr).safeTransferFrom(msg.sender, pairAddr, liquidity);

        // Burn LP tokens
        pair.burnLP(msg.sender, liquidity);

        // Remove liquidity
        (amountA, amountB) = _removeLiquidity(
            poolKey,
            liquidity,
            amountAMin,
            amountBMin,
            to
        );

        // Emit event
        emit LiquidityRemoved(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity,
            to
        );

        return (amountA, amountB);
    }

    /**
     * @dev Parameters required for adding liquidity to a pool
     * @param tokenA Address of first token in the pair
     * @param tokenB Address of second token in the pair
     * @param amountADesired Maximum amount of tokenA to deposit
     * @param amountBDesired Maximum amount of tokenB to deposit
     * @param amountAMin Minimum acceptable amount of tokenA to deposit
     * @param amountBMin Minimum acceptable amount of tokenB to deposit
     * @param to Recipient address for the liquidity tokens
     */
    struct LiquidityParams {
        address tokenA;
        address tokenB;
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
    }

    /**
     * @dev Handles the complete liquidity addition process
     * @param params Struct containing all liquidity addition parameters
     * @return amountA Actual amount of tokenA deposited
     * @return amountB Actual amount of tokenB deposited
     * @return liquidity Amount of liquidity tokens minted
     * @notice Sorts tokens, calculates optimal amounts, and processes the deposit
     */
    function _addLiquidityInternal(
        LiquidityParams memory params
    ) internal returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Get sorted tokens
        (address token0, address token1) = UniswapV4Utils.sortTokens(
            params.tokenA,
            params.tokenB
        );

        // Calculate amounts
        (amountA, amountB) = _calculateLiquidityAmounts(
            params.tokenA,
            params.tokenB,
            params.amountADesired,
            params.amountBDesired,
            params.amountAMin,
            params.amountBMin
        );

        // Process liquidity addition
        return
            _processLiquidityAddition(
                ProcessLiquidityParams({
                    tokenA: params.tokenA,
                    tokenB: params.tokenB,
                    token0: token0,
                    token1: token1,
                    amountA: amountA,
                    amountB: amountB,
                    to: params.to
                })
            );
    }

    /**
     * @dev Parameters for processing liquidity addition after calculation
     * @param tokenA Original first token address (unsorted)
     * @param tokenB Original second token address (unsorted)
     * @param token0 Sorted first token address
     * @param token1 Sorted second token address
     * @param amountA Amount of tokenA to deposit
     * @param amountB Amount of tokenB to deposit
     * @param to Recipient address for the liquidity tokens
     */
    struct ProcessLiquidityParams {
        address tokenA;
        address tokenB;
        address token0;
        address token1;
        uint256 amountA;
        uint256 amountB;
        address to;
    }

    /**
     * @dev Executes the actual liquidity addition to the pool
     * @param params Struct containing processed liquidity parameters
     * @return amountA Actual amount of tokenA deposited
     * @return amountB Actual amount of tokenB deposited
     * @return liquidity Amount of liquidity tokens minted
     * @notice Transfers tokens, interacts with PoolManager, and mints LP tokens
     * @dev Ensures minimum liquidity is maintained and emits LiquidityAdded event
     */
    function _processLiquidityAddition(
        ProcessLiquidityParams memory params
    ) internal returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Sort amounts according to token order
        uint256 amount0 = params.tokenA == params.token0
            ? params.amountA
            : params.amountB;
        uint256 amount1 = params.tokenA == params.token0
            ? params.amountB
            : params.amountA;

        // Transfer tokens to PoolManager
        if (amount0 > 0)
            IERC20(params.token0).safeTransferFrom(
                msg.sender,
                address(poolManager),
                amount0
            );
        if (amount1 > 0)
            IERC20(params.token1).safeTransferFrom(
                msg.sender,
                address(poolManager),
                amount1
            );

        // Add liquidity through PoolManager
        PoolKey memory poolKey = _getPoolKey(params.token0, params.token1);
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: UniswapV4Utils.MIN_TICK,
                tickUpper: UniswapV4Utils.MAX_TICK,
                liquidityDelta: int256(
                    CPAMMUtils.calculateInitialLiquidity(amount0, amount1)
                ),
                salt: bytes32(0)
            }),
            "" // Empty hook data
        );

        // Calculate liquidity from delta
        int256 deltaAmount = delta.amount0();
        liquidity = uint256(deltaAmount < 0 ? -deltaAmount : deltaAmount);
        liquidity = liquidity > CPAMMUtils.MIN_LIQUIDITY
            ? liquidity - CPAMMUtils.MIN_LIQUIDITY
            : liquidity;

        // Set return amounts
        amountA = params.amountA;
        amountB = params.amountB;

        // Emit event
        emit LiquidityAdded(
            msg.sender,
            params.tokenA,
            params.tokenB,
            amountA,
            amountB,
            liquidity,
            params.to
        );

        // Mint LP tokens to the user
        PoolId poolId = poolKey.toId();
        address pairAddr = factory.getPair(poolId);
        UniswapV4Pair(pairAddr).mintLP(params.to, liquidity);

        return (amountA, amountB, liquidity);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible
     * @param amountIn Exact amount of input tokens to send
     * @param amountOutMin Minimum amount of output tokens to receive
     * @param path Array of token addresses representing the swap path
     * @param to Recipient address of the output tokens
     * @param deadline Deadline timestamp for the transaction
     * @return amounts Array of input/output amounts at each swap step
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (path.length < 2) revert InvalidPath();
        if (amountIn == 0) revert InvalidSwapAmount(); // Check added here

       // we only need to record how much actually came out of each hop
       amounts = new uint256[](path.length);
       amounts[0] = amountIn;

       for (uint i = 0; i < path.length - 1; i++) {
         // this will pull in amountIn at first hop, then use
         // the output of the prior hop as the next input:
         uint256 out = _swap(
           path[i],        // tokenIn
           path[i+1],      // tokenOut
           path[i] < path[i+1] ? 0 : amounts[i], /* amount0Out */  
           path[i] < path[i+1] ? amounts[i] : 0, /* amount1Out */  
           i < path.length - 2 ? address(this) : to
         );

         // enforce minimum on the very last hop
         if (i == path.length - 2 && out < amountOutMin)
             revert InsufficientOutputAmount(amountOutMin, out);

         amounts[i+1] = out;
       }
       return amounts;
    }

    /**
     * @dev Calculates optimal token amounts for liquidity addition
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @param amountADesired Desired amount of tokenA to deposit
     * @param amountBDesired Desired amount of tokenB to deposit
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @return amountA Optimal amount of tokenA to deposit
     * @return amountB Optimal amount of tokenB to deposit
     * @notice Uses current reserves to calculate proportional amounts
     * @dev For new pools, uses desired amounts directly
     */
    function _calculateLiquidityAmounts(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (address token0, address token1) = UniswapV4Utils.sortTokens(
            tokenA,
            tokenB
        );
        PoolId poolId = factory.getPoolId(token0, token1);
        address hook = factory.getHook(poolId);
        (uint256 reserve0, uint256 reserve1) = ICPAMMHook(hook).getReserves(
            poolId
        );

        if (reserve0 == 0 && reserve1 == 0) {
            // New pool: use desired amounts directly
            amountA = amountADesired;
            amountB = amountBDesired;
        } else {
            // Existing pool: calculate optimal amounts based on reserves
            uint256 amountBOptimal = quote(amountADesired, reserve0, reserve1);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "Insufficient amount B");
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                uint256 amountAOptimal = quote(
                    amountBDesired,
                    reserve1,
                    reserve0
                );
                require(amountAOptimal <= amountADesired, "Excessive amount A");
                require(amountAOptimal >= amountAMin, "Insufficient amount A");
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
        }
        return (amountA, amountB);
    }

    /**
     * @dev Calculates proportional output amount given input amount and reserves
     * @param amountA Input amount of tokenA
     * @param reserveA Reserve amount of tokenA
     * @param reserveB Reserve amount of tokenB
     * @return amountB Proportional output amount of tokenB
     * @notice Uses simple ratio calculation: amountB = (amountA * reserveB) / reserveA
     */
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        require(amountA > 0, "Insufficient amount");
        require(reserveA > 0 && reserveB > 0, "Insufficient liquidity");
        amountB = (amountA * reserveB) / reserveA;
    }

    /**
     * @dev Internal function to add liquidity to a pool
     * @param token0 Address of the first token in the pair
     * @param token1 Address of the second token in the pair
     * @param amount0 Amount of token0 to add as liquidity
     * @param amount1 Amount of token1 to add as liquidity
     * @return liquidity Amount of liquidity tokens minted
     * @notice Adds liquidity to an existing pool or creates a new pool if needed
     * @dev Uses the pool manager to modify liquidity position with full-range ticks
     *      Calculates initial liquidity based on geometric mean of amounts
     *      Returns absolute value of delta.amount0() as liquidity amount
     * @custom:requirements 
     *      - Tokens must be valid ERC20 tokens
     *      - Pool must exist or be creatable
     *      - Amounts must be greater than zero
     * @custom:interactions 
     *      - Calls _getPoolKey() to get pool parameters
     *      - Interacts with poolManager.modifyLiquidity()
     *      - Uses CPAMMUtils.calculateInitialLiquidity()
     */
    function _addLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 liquidity) {
        // Create or get pool key
        PoolKey memory poolKey = _getPoolKey(token0, token1);

        // Add liquidity through pool manager
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: UniswapV4Utils.MIN_TICK,
                tickUpper: UniswapV4Utils.MAX_TICK,
                liquidityDelta: int256(
                    CPAMMUtils.calculateInitialLiquidity(amount0, amount1)
                ),
                salt: bytes32(0)
            }),
            "" // Empty hook data
        );

        // Convert delta.amount0() to positive uint256
        int128 amount = delta.amount0();
        if (amount < 0) amount = -amount;
        return uint256(uint128(amount));
    }

    /**
     * @dev Executes a series of token swaps along a specified path
     * @param amounts Array of input/output amounts at each swap step (from getAmountsOut)
     * @param path Array of token addresses representing the swap path
     * @param to Recipient address for the final output tokens
     * @notice Processes multi-hop swaps by iterating through the path and executing individual swaps
     * @dev For intermediate swaps (not the final hop), sends tokens to this contract to enable subsequent swaps
     *      Uses _swap() for each individual token pair swap
     *      Amounts array should be pre-calculated using getAmountsOut()
     * @custom:reverts If path length is invalid (checked in calling function)
     */
    function _executeSwaps(
        uint256[] memory amounts,
        address[] calldata path,
        address to
    ) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV4Utils.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];

            // Swap tokens through pool manager
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));

            address recipient = i < path.length - 2 ? address(this) : to;

            _swap(input, output, amount0Out, amount1Out, recipient);
        }
    }

    /**
     * @dev Gets an existing pool ID or creates a new pool if none exists
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @return poolId The ID of the existing or newly created pool
     * @notice Sorts tokens and uses default fee tier when creating new pools
     * @dev Creates pool with MIN_SQRT_RATIO as initial sqrtPriceX96
     * @custom:reverts If factory createPool fails
     */
    function getOrCreatePool(
        address tokenA,
        address tokenB
    ) internal returns (PoolId poolId) {
        (address token0, address token1) = UniswapV4Utils.sortTokens(
            tokenA,
            tokenB
        );

        // Try to get existing pool
        poolId = UniswapV4Utils
            .createPoolKey(token0, token1, CPAMMUtils.DEFAULT_FEE, address(0))
            .toId();

        // Create pool if it doesn't exist
        if (!factory.poolExists(poolId)) {
            (poolId, ) = factory.createPool(
                token0,
                token1,
                CPAMMUtils.DEFAULT_FEE,
                UniswapV4Utils.MIN_SQRT_RATIO
            );
        }
    }

    /**
     * @dev Gets current reserves for a token pair
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @return reserveA Reserve amount of tokenA
     * @return reserveB Reserve amount of tokenB
     * @notice Returns reserves in original token order (not necessarily sorted)
     */
    function _getReserves(
        address tokenA,
        address tokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, address token1) = UniswapV4Utils.sortTokens(
            tokenA,
            tokenB
        );
        // Use factory to get the actual poolId
        PoolId poolId = factory.getPoolId(token0, token1);
        // Get hook address from factory
        address hook = factory.getHook(poolId);
        (uint256 reserve0, uint256 reserve1) = ICPAMMHook(hook).getReserves(
            poolId
        );
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    /**
     * @notice Calculates the expected output amounts for a given swap
     * @param amountIn Amount of input tokens
     * @param path Array of token addresses representing the swap path
     * @return amounts Array of expected input/output amounts at each swap step
     */
    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = _getReserves(
                path[i],
                path[i + 1]
            );
            if (reserveIn == 0 || reserveOut == 0)
                revert InsufficientLiquidity(
                    reserveIn,
                    reserveOut,
                    CPAMMUtils.MIN_LIQUIDITY
                );

            uint256 amountInWithFee = amounts[i] * 997;
            uint256 numerator = amountInWithFee * reserveOut;
            uint256 denominator = (reserveIn * 1000) + amountInWithFee;
            amounts[i + 1] = numerator / denominator;
        }
    }
  
    /**
     * @dev Executes a single token swap between two assets
     * @param tokenIn Address of input token
     * @param tokenOut Address of output token
     * @param amount0OutArg Amount of token0 to output (0 if not token0)
     * @param amount1OutArg Amount of token1 to output (0 if not token1)
     * @param to Recipient address for the output tokens
     * @return actualOut Actual amount of output tokens received
     * @notice Handles token transfers, executes swap through PoolManager, and emits Swap event
     * @dev Uses MockPoolManager for token transfers in test environment
     */
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amount0OutArg,
        uint256 amount1OutArg,
        address to
    ) internal returns (uint256 actualOut) {
        // 1) VALIDATION UNCHANGED
        if (amount0OutArg == 0 && amount1OutArg == 0)
            revert InvalidSwapAmount();
        if (to == address(0)) revert InvalidRecipient(to);

        // 2) SORT TOKENS → currency0/currency1
        (address currency0, address currency1) = UniswapV4Utils.sortTokens(
            tokenIn,
            tokenOut
        );
        PoolKey memory poolKey = _getPoolKey(currency0, currency1);
        PoolId poolId = poolKey.toId();
        if (!factory.poolExists(poolId)) revert PoolDoesNotExist(poolId);

        // ─── NEW: figure out exactly how much was sent in
        uint256 amountIn = amount0OutArg > 0 ? amount0OutArg : amount1OutArg;
        // pull that from the user to PoolManager
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(poolManager), amountIn);

        // 3) DO THE SWAP via PoolManager
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: tokenIn == currency0,
                amountSpecified: tokenIn == currency0
                    ? int256(amount0OutArg)
                    : int256(amount1OutArg),
                sqrtPriceLimitX96: 0
            }),
            ""
        );

        // 4) figure out how much actually left the pool
        actualOut = tokenIn == currency0
          ? uint256(int256(delta.amount1()))
          : uint256(int256(delta.amount0()));

        //  ─── NEW: router now has the out tokens (mockPoolManager transferred them here),
        // so forward them to `to`
        MockPoolManager(address(poolManager))
            .transferTokens(tokenOut, to, actualOut);

        // 5) EMIT Swap in the canonical currency‑sorted order
        uint256 amount0InEvt = tokenIn == currency0 ? amountIn : 0;
        uint256 amount1InEvt = tokenIn == currency1 ? amountIn : 0;
        uint256 amount0OutEvt = tokenOut == currency0 ? actualOut : 0;
        uint256 amount1OutEvt = tokenOut == currency1 ? actualOut : 0;
        emit Swap(msg.sender, amount0InEvt, amount1InEvt, amount0OutEvt, amount1OutEvt, to);

        return actualOut;
    }


    /**
     * @dev Retrieves pool key for a given token pair
     * @param token0 First token in the pair
     * @param token1 Second token in the pair
     * @return PoolKey struct containing pool parameters
     * @notice Gets fee and hook information from factory
     */
    function _getPoolKey(
        address token0,
        address token1
    ) internal view returns (PoolKey memory) {
        // Get pool ID from factory
        PoolId poolId = factory.getPoolId(token0, token1);
        // Get pool key using factory's method
        (, , uint24 fee, address hook) = factory.getPoolKey(poolId);

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
     * @dev Removes liquidity from a pool and transfers tokens to recipient
     * @param poolKey Pool key identifying the liquidity pool
     * @param liquidity Amount of liquidity tokens to burn
     * @param amountAMin Minimum acceptable amount of tokenA to receive
     * @param amountBMin Minimum acceptable amount of tokenB to receive
     * @param to Recipient address for the withdrawn tokens
     * @return amountA Actual amount of tokenA received
     * @return amountB Actual amount of tokenB received
     * @notice Handles negative delta amounts from PoolManager and checks minimums
     */
    function _removeLiquidity(
        PoolKey memory poolKey,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) internal returns (uint256 amountA, uint256 amountB) {
        // Remove liquidity through pool manager
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: UniswapV4Utils.MIN_TICK,
                tickUpper: UniswapV4Utils.MAX_TICK,
                liquidityDelta: -int256(liquidity), // Negative for removal
                salt: bytes32(0)
            }),
            "" // Empty hook data
        );

        // Convert delta amounts to uint256, handling negative values properly
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        amountA = uint256(uint128(amount0 > 0 ? amount0 : -amount0));
        amountB = uint256(uint128(amount1 > 0 ? amount1 : -amount1));

        // Check minimum amounts
        if (amountA < amountAMin)
            revert InsufficientAmount(amountA, amountAMin);
        if (amountB < amountBMin)
            revert InsufficientAmount(amountB, amountBMin);

        // Transfer tokens to recipient
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
}
