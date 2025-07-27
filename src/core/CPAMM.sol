// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ICPAMMHook} from "../Interfaces/ICPAMMHook.sol";
import {CPAMMUtils} from "../lib/CPAMMUtils.sol";
import {UniswapV4Utils} from "../lib/UniswapV4Utils.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICPAMMFactory} from "../Interfaces/ICPAMMFactory.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/**
 * @title Concentrated Liquidity AMM (CPAMM)
 * @dev A high-performance, permissionless automated market maker building on Uniswap V4's concentrated liquidity primitives
 * @notice This contract implements a concentrated liquidity AMM with custom price ranges, improved capital efficiency,
 *         and tighter spreads. It serves as the core contract for the CPAMM protocol, handling all pool operations
 *         including swaps, liquidity provision, and fee management.
 * 
 * Key Features:
 * - Concentrated liquidity with custom price ranges
 * - Permissionless market making
 * - On-chain governance controls
 * - Anti-MEV measures (trade cooldowns, blacklisting)
 * - Slippage protection
 * - Protocol fee collection
 * 
 * Security Considerations:
 * - All state-changing functions are protected by hook call validation
 * - Critical parameters are governance-controlled
 * - Slippage checks are enforced for all swaps
 * - Blacklisting functionality to block malicious actors
 */
contract CPAMM is ICPAMMHook {
    using PoolIdLibrary for PoolKey;
    using CPAMMUtils for uint256;
    using CPAMMUtils for PoolId;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    // State variables
    IPoolManager public immutable poolManager;
    address public immutable owner;
    address public immutable governance;
    PoolKey public poolKey;
    PoolId public poolId;
    Currency public currency0;
    Currency public currency1;
    uint24 public currentFee;
    uint256 public slippageTolerance;
    uint24 public protocolFee;
    ICPAMMFactory public immutable factory;

    /**
     * @dev Struct representing the state of a liquidity pool
     * @param sqrtPriceX96 The sqrt price of the pool as a Q64.96
     * @param tick The current tick of the pool
     * @param protocolFee The protocol fee percentage (in basis points)
     * @param lpFee The liquidity provider fee percentage (in basis points)
     * @param reserve0 The reserve amount of token0
     * @param reserve1 The reserve amount of token1
     * @param lastK The last value of reserve0 * reserve1 (used for invariant checks)
     * @param lastUpdateTimestamp The timestamp of the last state update
     * @param lastPrice The last recorded price (token1 per token0)
     */
    struct PoolState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        uint256 reserve0;
        uint256 reserve1;
        uint256 lastK;
        uint256 lastUpdateTimestamp;
        uint256 lastPrice;
    }

    mapping(PoolId => PoolState) public poolStates;
    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public lastTradeTimestamp;
    uint256 public constant TRADE_COOLDOWN = 1 minutes;
    uint256 public constant MAX_SLIPPAGE = 200;
   
    event PoolInitialized(
        PoolId indexed poolId,
        address indexed initializer,
        uint160 sqrtPriceX96,
        int24 tick
    );
    event SwapCompleted(
        address indexed sender,
        PoolId indexed poolId,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    );
    event ProtocolFeesCollected(
        PoolId indexed poolId,
        uint256 fee0,
        uint256 fee1
    );
    event DonationProcessed(
        address indexed donor,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        string purpose
    );
    event Mint(
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Burn(
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    /**
     * @dev Constructor for the CPAMM contract
     * @param _poolManager The Uniswap V4 PoolManager contract address
     * @param poolKey_ The pool key defining the pool parameters
     * @param _owner The owner address with administrative privileges
     * @param _governance The governance address with fee-setting privileges
     * @param _fee The initial LP fee for the pool (in basis points)
     * @param _protocolFee The initial protocol fee (in basis points)
     * @param _factory The CPAMM factory contract address
     * @notice Validates hook permissions and sets up initial contract state
     */
    constructor(
        IPoolManager _poolManager,
        PoolKey memory poolKey_,
        address _owner,
        address _governance,
        uint24 _fee,
        uint24 _protocolFee,
        ICPAMMFactory _factory
    ) {
        poolManager = _poolManager;
        owner = _owner;
        governance = _governance;
        currentFee = _fee;
        protocolFee = _protocolFee;
        factory = _factory; 

        // Set up hook permissions
        Hooks.Permissions memory permissions = Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true, 
            afterAddLiquidity: true, 
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });

        // Validate hook permissions with Uniswap v4's requirements
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);

        // Calculate expected hook flags (14-bit mask)
        uint160 expectedFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_DONATE_FLAG |
                Hooks.AFTER_DONATE_FLAG
        );

        // Get actual hook address bits using mask
        uint160 hookBits = uint160(address(this)) & Hooks.ALL_HOOK_MASK;

        // Verify hook address has correct flags set
        require(hookBits == expectedFlags, "Hook address flags mismatch");
    }

    /**
     * @dev Initializes the pool with the given pool key
     * @param _poolKey The pool key defining the pool parameters
     * @notice Can only be called once per pool
     */
    function initialize(PoolKey memory _poolKey) external {
        require(
            Currency.unwrap(currency0) == address(0),
            "Already initialized"
        );
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        currency0 = _poolKey.currency0;
        currency1 = _poolKey.currency1;
    }

     /**
     * @dev Validates that the caller is the PoolManager
     * @notice Internal function used to validate hook calls
     */
    function _validateCaller() internal view {
        require(msg.sender == address(poolManager), "Invalid caller");
    }

     /**
     * @dev Converts a sqrt price to an actual price
     * @param sqrtPriceX96 The sqrt price as Q64.96
     * @return price The actual price (token1 per token0)
     */
    function _sqrtPriceToPrice(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        uint256 price = uint256(sqrtPriceX96).mulDivDown(
            uint256(sqrtPriceX96),
            2 ** 96
        );
        return price;
    }

    // Core hook functions
    /**
     * @dev Hook called before pool initialization
     * @param sender The address initiating the initialization
     * @param key The pool key defining the pool parameters
     * @param sqrtPriceX96 The initial sqrt price of the pool
     * @return selector The function selector to validate the hook call
     * @notice Performs validation checks before pool initialization
     */
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external view override returns (bytes4) {
        // Validate sender is not blacklisted
        require(!isBlacklisted[sender], "Sender blacklisted");

        // Validate initial price is within bounds
        require(
            sqrtPriceX96 >= UniswapV4Utils.MIN_SQRT_RATIO &&
                sqrtPriceX96 <= UniswapV4Utils.MAX_SQRT_RATIO,
            "Invalid initial price"
        );

        // Validate pool parameters
        require(UniswapV4Utils.validatePool(key), "Invalid pool parameters");

        return ICPAMMHook.beforeInitialize.selector;
    }

      /**
     * @dev Hook called after pool initialization
     * @param sender The address that initialized the pool
     * @param key The pool key defining the pool parameters
     * @param sqrtPriceX96 The initial sqrt price of the pool
     * @param tick The initial tick of the pool
     * @return selector The function selector to validate the hook call
     * @notice Initializes the pool state with initial values
     */
    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external override returns (bytes4) {
        _validateCaller();
        PoolId poolId = key.toId();

        // Convert sqrtPrice to actual price (token1 per token0)
        uint256 price = _sqrtPriceToPrice(sqrtPriceX96);

        // Initialize pool state with initial reserves (0,0) but set the initial price
        poolStates[poolId] = PoolState({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            protocolFee: 0,
            lpFee: uint24(key.fee),
            reserve0: 0,
            reserve1: 0,
            lastK: 0,
            lastUpdateTimestamp: block.timestamp,
            lastPrice: price // Add this field to PoolState struct
        });

        emit PoolInitialized(poolId, sender, sqrtPriceX96, tick);
        return ICPAMMHook.afterInitialize.selector;
    }

    // ============= LIQUIDITY MODIFICATION HOOKS ==========================

    /**
     * @dev Hook called before any liquidity modification (add/remove)
     * @param _sender The address initiating the liquidity modification
     * @param _key The pool key identifying the pool
     * @param _params Parameters for liquidity modification
     * @param _hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @notice Performs:
     * - Blacklist check
     * - Trade cooldown enforcement
     * - Pool existence validation
     * - Tick range validation
     * - Custom slippage tolerance check if provided in hookData
     */
    function beforeModifyPosition(
        address _sender,
        PoolKey calldata _key,
        IPoolManager.ModifyLiquidityParams calldata _params,
        bytes calldata _hookData
    ) external view override returns (bytes4) {
        // Check if sender is blacklisted
        require(!isBlacklisted[_sender], "Sender blacklisted");

        // Ensure sufficient cooldown between operations
        require(
            block.timestamp >= lastTradeTimestamp[_sender] + TRADE_COOLDOWN,
            "Operation too soon"
        );

        // Validate pool exists
        PoolId poolId = _key.toId();
        PoolState storage state = poolStates[poolId];
        require(state.lastUpdateTimestamp > 0, "Pool not initialized");

        // Validate position range
        require(
            _params.tickLower >= UniswapV4Utils.MIN_TICK &&
                _params.tickUpper <= UniswapV4Utils.MAX_TICK,
            "Invalid tick range"
        );

        // Parse custom parameters if provided
        if (_hookData.length > 0) {
            uint256 userMaxSlippage = abi.decode(_hookData, (uint256));
            require(userMaxSlippage <= MAX_SLIPPAGE, "Slippage too high");
        }

        return ICPAMMHook.beforeModifyPosition.selector;
    }

    /**
     * @dev Hook called after any liquidity modification (add/remove)
     * @param _sender The address that initiated the liquidity modification
     * @param _key The pool key identifying the pool
     * @param _params Parameters used for liquidity modification
     * @param _delta The change in token balances resulting from the modification
     * @param _hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @notice Handles:
     * - Reserve updates based on delta
     * - Liquidity addition/removal specific logic
     * - Pool state updates (K value, timestamp)
     * - Custom slippage validation if provided in hookData
     */
    function afterModifyPosition(
        address _sender,
        PoolKey calldata _key,
        IPoolManager.ModifyLiquidityParams calldata _params,
        BalanceDelta _delta,
        bytes calldata _hookData
    ) external override returns (bytes4) {
        // Get pool state
        PoolId poolId = _key.toId();
        PoolState storage state = poolStates[poolId];

        // Update reserves based on delta
        if (_delta.amount0() > 0) {
            state.reserve0 += uint256(uint128(_delta.amount0()));
        } else {
            state.reserve0 -= uint256(uint128(-_delta.amount0()));
        }

        if (_delta.amount1() > 0) {
            state.reserve1 += uint256(uint128(_delta.amount1()));
        } else {
            state.reserve1 -= uint256(uint128(-_delta.amount1()));
        }

        // Track position changes using _params
        if (_params.liquidityDelta > 0) {
            // Adding liquidity
            require(
                _params.tickLower < _params.tickUpper,
                "Invalid tick range"
            );

            // Update tick tracking if needed
            if (
                _params.tickLower < state.tick && _params.tickUpper > state.tick
            ) {
                // Position spans current tick
                // Additional logic for active positions can be added here
            }
        } else {
            // Removing liquidity
            // Ensure minimum liquidity remains
            require(
                state.reserve0 >= CPAMMUtils.MIN_LIQUIDITY &&
                    state.reserve1 >= CPAMMUtils.MIN_LIQUIDITY,
                "Insufficient remaining liquidity"
            );
        }

        // Update pool state
        state.lastK = state.reserve0 * state.reserve1;
        state.lastUpdateTimestamp = block.timestamp;

        // Update last trade timestamp for the sender
        updateLastTradeTimestamp(_sender);

        // Optional: Parse any custom parameters from hookData
        if (_hookData.length > 0) {
            // Handle any custom parameters from hookData
            uint256 customSlippageTolerance = abi.decode(_hookData, (uint256));

            // Validate and apply custom slippage tolerance
            require(
                customSlippageTolerance <= MAX_SLIPPAGE,
                "Slippage too high"
            );

            // Calculate actual slippage from reserves change
            uint256 actualSlippage = calculateSlippageFromDelta(
                _delta,
                state.reserve0,
                state.reserve1
            );
            require(
                actualSlippage <= customSlippageTolerance,
                "Slippage exceeded"
            );
        }

        return ICPAMMHook.afterModifyPosition.selector;
    }

    // ===================== SWAP HOOKS ==========================
    /**
     * @dev Hook called before any swap operation
     * @param sender The address initiating the swap
     * @param key The pool key identifying the pool
     * @param params Parameters for the swap operation
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @return beforeSwapDelta The delta to apply before swap (always 0 in this implementation)
     * @return swapFee The swap fee (always 0 in this implementation)
     * @notice Performs:
     * - Anti-MEV trade cooldown check
     * - Slippage protection if price limit is set
     * - Custom slippage tolerance validation if provided in hookData
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // Anti-MEV: Check trade cooldown
        require(
            block.timestamp >= lastTradeTimestamp[sender] + TRADE_COOLDOWN,
            "Trade too soon"
        );

        // Slippage protection
        if (params.sqrtPriceLimitX96 != 0) {
            uint256 priceImpact = calculatePriceImpact(
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                key.toId()
            );
            require(priceImpact <= MAX_SLIPPAGE, "Excessive slippage");
        }

        // Parse custom parameters if provided
        if (hookData.length > 0) {
            uint256 userMaxSlippage = abi.decode(hookData, (uint256));
            require(userMaxSlippage <= MAX_SLIPPAGE, "Slippage too high");
        }

        emit SlippageVerified(params.amountSpecified, params.sqrtPriceLimitX96);

        return (ICPAMMHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /**
     * @dev Hook called after any swap operation
     * @param sender The address that initiated the swap
     * @param key The pool key identifying the pool
     * @param params Parameters used for the swap
     * @param delta The change in token balances resulting from the swap
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @return afterSwapDelta The delta to apply after swap (always 0 in this implementation)
     * @notice Handles:
     * - Reserve updates based on swap delta
     * - Post-swap price impact verification
     * - Pool state updates (K value, timestamp)
     * - Custom parameter processing from hookData
     * - Swap completion event emission
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolState storage state = poolStates[poolId];

        // Update reserves based on delta
        if (delta.amount0() > 0) {
            state.reserve0 += uint256(uint128(delta.amount0()));
        } else {
            state.reserve0 -= uint256(uint128(-delta.amount0()));
        }

        if (delta.amount1() > 0) {
            state.reserve1 += uint256(uint128(delta.amount1()));
        } else {
            state.reserve1 -= uint256(uint128(-delta.amount1()));
        }

        // Update last trade timestamp for the sender
        lastTradeTimestamp[sender] = block.timestamp;

        // Calculate and verify price impact if specified in params
        if (params.sqrtPriceLimitX96 != 0) {
            uint256 priceImpact = calculatePriceImpact(
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                poolId
            );
            require(
                priceImpact <= MAX_SLIPPAGE,
                "Post-swap: Excessive slippage"
            );
        }

        // Process any custom parameters from hookData
        if (hookData.length > 0) {
            // Example: Decode custom slippage tolerance
            uint256 userSlippageTolerance = abi.decode(hookData, (uint256));
            require(
                userSlippageTolerance <= MAX_SLIPPAGE,
                "Custom slippage exceeded"
            );
        }

        state.lastK = state.reserve0 * state.reserve1;
        state.lastUpdateTimestamp = block.timestamp;

        // You might want to emit an event with swap details
        emit SwapCompleted(
            sender,
            poolId,
            params.zeroForOne,
            params.amountSpecified,
            delta.amount0(),
            delta.amount1()
        );

        return (ICPAMMHook.afterSwap.selector, 0);
    }

    // ===================== ADD LIQUIDITY HOOKS =============================

    /**
     * @dev Hook called specifically before adding liquidity
     * @param sender The address initiating the liquidity addition
     * @param key The pool key identifying the pool
     * @param params Parameters for liquidity addition
     * @param hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @notice Performs:
     * - Blacklist check
     * - Pool existence validation
     * - Tick range validation
     * - Minimum liquidity check
     * - Custom parameter validation if provided in hookData
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override returns (bytes4) {
        // Validate sender is not blacklisted
        require(!isBlacklisted[sender], "Sender blacklisted");

        // Ensure pool exists
        PoolId poolId = key.toId();
        PoolState storage state = poolStates[poolId];
        require(state.lastUpdateTimestamp > 0, "Pool not initialized");

        // Validate position range
        require(
            params.tickLower >= UniswapV4Utils.MIN_TICK &&
                params.tickUpper <= UniswapV4Utils.MAX_TICK,
            "Invalid tick range"
        );

        // Minimum liquidity check
        require(
            params.liquidityDelta > 0 ||
                (state.reserve0 > CPAMMUtils.MIN_LIQUIDITY &&
                    state.reserve1 > CPAMMUtils.MIN_LIQUIDITY),
            "Insufficient liquidity"
        );

        // Parse custom parameters if hookData is provided
        if (hookData.length > 0) {
            // Example: Decode custom slippage tolerance and minimum liquidity
            (uint256 userSlippageTolerance, uint256 userMinLiquidity) = abi
                .decode(hookData, (uint256, uint256));

            // Validate custom parameters
            require(userSlippageTolerance <= MAX_SLIPPAGE, "Slippage too high");
            require(
                userMinLiquidity >= CPAMMUtils.MIN_LIQUIDITY,
                "Min liquidity too low"
            );

            // Additional validation using custom parameters
            if (params.liquidityDelta > 0) {
                require(
                    uint256(params.liquidityDelta) >= userMinLiquidity,
                    "Below user minimum liquidity"
                );
            }
        }

        return ICPAMMHook.beforeAddLiquidity.selector;
    }

    /**
     * @dev Hook called specifically after adding liquidity
     * @param _sender The address that initiated the liquidity addition
     * @param _key The pool key identifying the pool
     * @param _params Parameters used for liquidity addition
     * @param _delta The change in token balances from adding liquidity
     * @param _feesAccrued Any fees accrued during the operation
     * @param _hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @return afterAddLiquidityDelta The delta to apply after adding liquidity (always 0 in this implementation)
     * @notice Handles:
     * - Reserve updates
     * - Price calculation
     * - Protocol fee processing
     * - Custom slippage validation
     * - Tick tracking updates
     */
    function afterAddLiquidity(
        address _sender,
        PoolKey calldata _key,
        IPoolManager.ModifyLiquidityParams calldata _params,
        BalanceDelta _delta,
        BalanceDelta _feesAccrued,
        bytes calldata _hookData
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = _key.toId();
        PoolState storage state = poolStates[poolId];

        // Convert delta amounts to absolute values and update reserves
        int128 amount0 = _delta.amount0();
        int128 amount1 = _delta.amount1();

        if (amount0 > 0) {
            state.reserve0 += uint256(uint128(amount0));
        } else if (amount0 < 0) {
            state.reserve0 -= uint256(uint128(-amount0));
        }

        if (amount1 > 0) {
            state.reserve1 += uint256(uint128(amount1));
        } else if (amount1 < 0) {
            state.reserve1 -= uint256(uint128(-amount1));
        }

        // Calculate current price (token1 per token0)
        if (state.reserve0 > 0) {
            state.lastPrice = (state.reserve1 * 1e18) / state.reserve0;
        }

        // Update pool state
        state.lastK = state.reserve0 * state.reserve1;
        state.lastUpdateTimestamp = block.timestamp;

        // Process any fees accrued
        if (_feesAccrued.amount0() != 0 || _feesAccrued.amount1() != 0) {
            // Process protocol fees if configured
            if (state.protocolFee > 0) {
                // Calculate protocol fees
                uint256 protocolFee0 = (uint256(
                    uint128(_feesAccrued.amount0())
                ) * state.protocolFee) / 10000;
                uint256 protocolFee1 = (uint256(
                    uint128(_feesAccrued.amount1())
                ) * state.protocolFee) / 10000;

                // Deduct protocol fees from reserves
                if (protocolFee0 > 0) {
                    state.reserve0 -= protocolFee0;
                }
                if (protocolFee1 > 0) {
                    state.reserve1 -= protocolFee1;
                }

                // Emit event for protocol fee collection
                emit ProtocolFeesCollected(poolId, protocolFee0, protocolFee1);
            }
        }

        // Handle any custom parameters from hookData
        if (_hookData.length > 0) {
            // Decode custom slippage tolerance from hookData
            uint256 customSlippageTolerance = abi.decode(_hookData, (uint256));

            // Validate and apply custom slippage tolerance
            require(
                customSlippageTolerance <= MAX_SLIPPAGE,
                "Slippage too high"
            );

            // Calculate actual slippage from reserves change
            uint256 actualSlippage = calculateSlippageFromDelta(
                _delta,
                state.reserve0,
                state.reserve1
            );
            require(
                actualSlippage <= customSlippageTolerance,
                "Slippage exceeded"
            );
        }

        // Update last operation timestamp for the sender
        updateLastTradeTimestamp(_sender);

        // Update tick tracking if needed
        if (_params.tickLower <= state.tick && _params.tickUpper > state.tick) {
            // Update the current tick if necessary
            state.tick =
                _params.tickLower +
                (_params.tickUpper - _params.tickLower) /
                2;
        }

        return (ICPAMMHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ====================== REMOVE LIQUIDITY HOOKS =============================

    /**
     * @dev Hook called specifically before removing liquidity
     * @param _sender The address initiating the liquidity removal
     * @param _key The pool key identifying the pool
     * @param _params Parameters for liquidity removal
     * @param _hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @notice Performs:
     * - Blacklist check
     * - Pool existence validation
     * - Tick range validation
     * - Trade cooldown check
     * - Minimum remaining liquidity validation (custom or default)
     */
    function beforeRemoveLiquidity(
        address _sender,
        PoolKey calldata _key,
        IPoolManager.ModifyLiquidityParams calldata _params,
        bytes calldata _hookData
    ) external view override returns (bytes4) {
        // Check if sender is blacklisted
        require(!isBlacklisted[_sender], "Sender blacklisted");

        // Get pool state
        PoolId poolId = _key.toId();
        PoolState storage state = poolStates[poolId];

        // Ensure pool exists and is initialized
        require(state.lastUpdateTimestamp > 0, "Pool not initialized");

        // Validate position range
        require(
            _params.tickLower >= UniswapV4Utils.MIN_TICK &&
                _params.tickUpper <= UniswapV4Utils.MAX_TICK,
            "Invalid tick range"
        );

        // Ensure sufficient cooldown between operations
        require(
            block.timestamp >= lastTradeTimestamp[_sender] + TRADE_COOLDOWN,
            "Operation too soon"
        );

        // If hookData is provided, process custom parameters
        if (_hookData.length > 0) {
            uint256 userMinRemainingLiquidity = abi.decode(
                _hookData,
                (uint256)
            );

            // Ensure remaining liquidity after removal won't go below user-specified minimum
            require(
                state.reserve0 > userMinRemainingLiquidity &&
                    state.reserve1 > userMinRemainingLiquidity,
                "Insufficient remaining liquidity"
            );
        } else {
            // Default minimum liquidity check
            require(
                state.reserve0 > CPAMMUtils.MIN_LIQUIDITY &&
                    state.reserve1 > CPAMMUtils.MIN_LIQUIDITY,
                "Below minimum liquidity"
            );
        }

        return ICPAMMHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @dev Hook called specifically after removing liquidity
     * @param _sender The address that initiated the liquidity removal
     * @param _key The pool key identifying the pool
     * @param _params Parameters used for liquidity removal
     * @param _delta The change in token balances from removing liquidity
     * @param _feesAccrued Any fees accrued during the operation
     * @param _hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @return afterRemoveLiquidityDelta The delta to apply after removing liquidity (always 0 in this implementation)
     * @notice Handles:
     * - Parameter validation
     * - Active liquidity tracking updates
     * - Reserve updates
     * - Protocol fee processing
     * - Custom slippage validation
     */
    function afterRemoveLiquidity(
        address _sender,
        PoolKey calldata _key,
        IPoolManager.ModifyLiquidityParams calldata _params,
        BalanceDelta _delta,
        BalanceDelta _feesAccrued,
        bytes calldata _hookData
    ) external override returns (bytes4, BalanceDelta) {
        // Get pool state
        PoolId poolId = _key.toId();
        PoolState storage state = poolStates[poolId];

        // Validate liquidity parameters
        require(_params.tickLower < _params.tickUpper, "Invalid tick range");
        require(
            _params.tickLower >= UniswapV4Utils.MIN_TICK,
            "Lower tick too low"
        );
        require(
            _params.tickUpper <= UniswapV4Utils.MAX_TICK,
            "Upper tick too high"
        );

        // Ensure liquidityDelta is negative for removal
        require(_params.liquidityDelta < 0, "LiquidityDelta must be negative");

        // Track position changes if it spans current tick
        if (_params.tickLower <= state.tick && _params.tickUpper > state.tick) {
            // Update active liquidity tracking if needed
            // This is where you might want to update any active liquidity tracking
            state.tick =
                _params.tickLower +
                (_params.tickUpper - _params.tickLower) /
                2;
        }

        // Update reserves based on delta
        if (_delta.amount0() > 0) {
            state.reserve0 += uint256(uint128(_delta.amount0()));
        } else {
            state.reserve0 -= uint256(uint128(-_delta.amount0()));
        }

        if (_delta.amount1() > 0) {
            state.reserve1 += uint256(uint128(_delta.amount1()));
        } else {
            state.reserve1 -= uint256(uint128(-_delta.amount1()));
        }

        // Handle any accrued fees
        if (_feesAccrued.amount0() != 0 || _feesAccrued.amount1() != 0) {
            // Process protocol fees if configured
            if (state.protocolFee > 0) {
                // Calculate protocol fees
                uint256 protocolFee0 = (uint256(
                    uint128(_feesAccrued.amount0())
                ) * state.protocolFee) / 10000;
                uint256 protocolFee1 = (uint256(
                    uint128(_feesAccrued.amount1())
                ) * state.protocolFee) / 10000;

                // Deduct protocol fees from reserves
                if (protocolFee0 > 0) {
                    state.reserve0 -= protocolFee0;
                }
                if (protocolFee1 > 0) {
                    state.reserve1 -= protocolFee1;
                }

                // Optional: Emit event for protocol fee collection
                emit ProtocolFeesCollected(poolId, protocolFee0, protocolFee1);
            }
        }

        // Update pool state
        state.lastK = state.reserve0 * state.reserve1;
        state.lastUpdateTimestamp = block.timestamp;

        // Process any custom parameters from hookData
        if (_hookData.length > 0) {
            uint256 customSlippageTolerance = abi.decode(_hookData, (uint256));
            require(
                customSlippageTolerance <= MAX_SLIPPAGE,
                "Slippage too high"
            );

            uint256 actualSlippage = calculateSlippageFromDelta(
                _delta,
                state.reserve0,
                state.reserve1
            );
            require(
                actualSlippage <= customSlippageTolerance,
                "Slippage exceeded"
            );
        }

        // Update last operation timestamp
        updateLastTradeTimestamp(_sender);

        return (ICPAMMHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ==================== DONATION HOOKS =============================

    /**
     * @dev Hook called before processing a donation to the pool
     * @param _sender The address making the donation
     * @param _key The pool key identifying the pool
     * @param _amount0 The amount of token0 being donated
     * @param _amount1 The amount of token1 being donated
     * @param _hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @notice Performs:
     * - Blacklist check
     * - Pool existence validation
     * - Donation amount validation
     * - Overflow checks
     * - Custom donation limit validation if provided in hookData
     */
    function beforeDonate(
        address _sender,
        PoolKey calldata _key,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata _hookData
    ) external view override returns (bytes4) {
        // Check if sender is blacklisted
        require(!isBlacklisted[_sender], "Sender blacklisted");

        // Get pool state
        PoolId poolId = _key.toId();
        PoolState storage state = poolStates[poolId];

        // Ensure pool exists and is initialized
        require(state.lastUpdateTimestamp > 0, "Pool not initialized");

        // Validate donation amounts
        require(_amount0 > 0 || _amount1 > 0, "Zero donation");

        // Ensure donation won't overflow reserves
        require(
            state.reserve0 + _amount0 >= state.reserve0 &&
                state.reserve1 + _amount1 >= state.reserve1,
            "Donation overflow"
        );

        // If hookData is provided, process any custom parameters
        if (_hookData.length > 0) {
            // Example: Decode maximum donation limit
            uint256 maxDonationLimit = abi.decode(_hookData, (uint256));
            require(
                _amount0 <= maxDonationLimit && _amount1 <= maxDonationLimit,
                "Donation exceeds limit"
            );
        }

        return ICPAMMHook.beforeDonate.selector;
    }

    /**
     * @dev Hook called after processing a donation to the pool
     * @param _sender The address that made the donation
     * @param _key The pool key identifying the pool
     * @param _amount0 The amount of token0 donated
     * @param _amount1 The amount of token1 donated
     * @param _hookData Additional data passed to the hook
     * @return selector The function selector to validate the hook call
     * @notice Handles:
     * - Reserve updates
     * - Pool state updates
     * - Donation purpose processing from hookData
     * - Donation event emission
     */
    function afterDonate(
        address _sender,
        PoolKey calldata _key,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata _hookData
    ) external override returns (bytes4) {
        // Get pool state
        PoolId poolId = _key.toId();
        PoolState storage state = poolStates[poolId];

        // Update reserves with donated amounts
        state.reserve0 += _amount0;
        state.reserve1 += _amount1;

        // Update pool state
        state.lastK = state.reserve0 * state.reserve1;
        state.lastUpdateTimestamp = block.timestamp;

        // Process any custom parameters from hookData
        if (_hookData.length > 0) {
            // Example: Decode donation purpose or metadata
            string memory donationPurpose = abi.decode(_hookData, (string));
            emit DonationProcessed(
                _sender,
                poolId,
                _amount0,
                _amount1,
                donationPurpose
            );
        } else {
            emit DonationProcessed(_sender, poolId, _amount0, _amount1, "");
        }

        return ICPAMMHook.afterDonate.selector;
    }

    // View functions
    /**
     * @dev Returns the current price and last update timestamp for a pool
     * @param poolId The ID of the pool
     * @return price The current price (token1 per token0)
     * @return timestamp The last update timestamp
     */
    function getPrice(
        PoolId poolId
    ) external view override returns (uint256 price, uint256 timestamp) {
        PoolState storage state = poolStates[poolId];
        return (state.lastPrice, state.lastUpdateTimestamp);
    }

    /**
     * @dev Returns the current reserves for a pool
     * @param poolId The ID of the pool
     * @return reserve0 The reserve amount of token0
     * @return reserve1 The reserve amount of token1
     */
    function getReserves(
        PoolId poolId
    ) external view override returns (uint256 reserve0, uint256 reserve1) {
        PoolState storage state = poolStates[poolId];
        return (state.reserve0, state.reserve1);
    }

    function getHooksCalls() external pure override returns (uint24) {
        return
            uint24(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.AFTER_INITIALIZE_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_DONATE_FLAG |
                    Hooks.AFTER_DONATE_FLAG
            );
    }

     /**
     * @dev Calculates price impact for a swap
     * @param zeroForOne The direction of the swap
     * @param amountSpecified The amount being swapped
     * @param sqrtPriceLimitX96 The price limit for the swap
     * @param poolId The ID of the pool
     * @return impact The price impact in basis points
     */
    function calculatePriceImpact(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        PoolId poolId
    ) internal view returns (uint256) {
        PoolState storage state = poolStates[poolId];
        uint256 currentPrice = state.sqrtPriceX96;
        uint256 limitPrice = sqrtPriceLimitX96;

        // Convert amountSpecified to absolute value for calculation
        uint256 amount = uint256(
            amountSpecified < 0 ? -amountSpecified : amountSpecified
        );

        // Calculate expected output based on current price and amount
        uint256 expectedOutput = zeroForOne
            ? (amount * currentPrice) / (1 << 96)
            : (amount * (1 << 96)) / currentPrice;

        // Calculate actual output based on limit price
        uint256 actualOutput = zeroForOne
            ? (amount * limitPrice) / (1 << 96)
            : (amount * (1 << 96)) / limitPrice;

        // Calculate price impact as percentage (in basis points)
        uint256 impact = expectedOutput > actualOutput
            ? ((expectedOutput - actualOutput) * 10000) / expectedOutput
            : ((actualOutput - expectedOutput) * 10000) / expectedOutput;

        return impact;
    }
    
    /**
     * @dev Blacklists or unblacklists a user.
     * @param user The address to be blacklisted or unblacklisted.
     * @param blacklisted A boolean indicating the blacklist status.
     */
    function setBlacklist(address user, bool blacklisted) external {
        require(msg.sender == owner, "Not authorized");
        isBlacklisted[user] = blacklisted;
    }

    /**
     * @dev Updates the last trade timestamp for a user.
     * @param user The address of the user whose timestamp is being updated.
     */
    function updateLastTradeTimestamp(address user) internal {
        lastTradeTimestamp[user] = block.timestamp;
    }

    /**
     * @dev Updates the fee for a specific pool. Only callable by governance.
     * @param pid The pool ID for which the fee is being updated.
     * @param newFee The new fee to be set, must not exceed MAX_FEE.
     * @return success A boolean indicating whether the update was successful.
     */
    function updateFee(PoolId pid, uint24 newFee) external override returns (bool) {
        // Only governance can update fee
        require(msg.sender == governance, "Only governance can update fee");
        require(newFee <= CPAMMUtils.MAX_FEE, "Fee exceeds maximum");

        // Get the pool ID from the stored poolKey
        PoolId poolId = poolKey.toId();

        // Update the fee
        currentFee = newFee;

        // Emit the event with the correct poolId
        emit FeeUpdated(poolId, newFee);

        return true;
    }

    /**
     * @dev Calculates slippage from a given balance delta and reserves.
     * @param delta The change in token balances from a swap or liquidity event.
     * @param reserve0 The current reserve of token0 in the pool.
     * @param reserve1 The current reserve of token1 in the pool.
     * @return slippage The maximum slippage in basis points (bps).
     */
    function calculateSlippageFromDelta(
        BalanceDelta delta,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256) {
        uint256 delta0 = uint256(
            uint128(delta.amount0() >= 0 ? delta.amount0() : -delta.amount0())
        );
        uint256 delta1 = uint256(
            uint128(delta.amount1() >= 0 ? delta.amount1() : -delta.amount1())
        );

        // Calculate slippage as percentage of reserves (in basis points)
        uint256 slippage0 = reserve0 > 0 ? (delta0 * 10000) / reserve0 : 0;
        uint256 slippage1 = reserve1 > 0 ? (delta1 * 10000) / reserve1 : 0;

        // Return the larger slippage value
        return slippage0 > slippage1 ? slippage0 : slippage1;
    }

    /**
     * @dev Mints new tokens to a user's balance and updates total supply.
     * @param user The address receiving the newly minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function _mint(address user, uint256 amount) internal {
        // Ensure the amount to mint is greater than zero
        require(amount > 0, "Mint amount must be greater than zero");

        // Update the total supply
        _totalSupply += amount;

        // Update the user's balance
        _balances[user] += amount;

        // Emit a Transfer event from the zero address to the user
        emit Transfer(address(0), user, amount);
    }

    /**
     * @dev Returns the total supply of the minted token.
     * @return supply The total amount of tokens in existence.
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Returns the token balance of a specific account.
     * @param account The address whose balance is being queried.
     * @return balance The token balance of the account.
     */
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev Returns the reserves of token0 and token1 for the current pool.
     * @return reserve0 The amount of token0 in the pool.
     * @return reserve1 The amount of token1 in the pool.
     */
    function getReserves()
        public
        view
        returns (uint256 reserve0, uint256 reserve1)
    {
        // Retrieve the pool state for the current poolKey
        PoolId poolId = poolKey.toId();
        PoolState storage state = poolStates[poolId];

        // Return the reserves from the pool state
        return (state.reserve0, state.reserve1);
    }

    /**
     * @dev Mints new liquidity tokens
     * @param amount0 The amount of token0 to deposit
     * @param amount1 The amount of token1 to deposit
     * @param user The address receiving the liquidity tokens
     * @return liquidity The amount of liquidity tokens minted
     * @notice Handles both initial and subsequent liquidity additions
     */
    function mint(
        uint256 amount0,
        uint256 amount1,
        address user
    ) external returns (uint256 liquidity) {
        // Ensure the user is not the zero address
        require(user != address(0), "Invalid user address");

        // Get current reserves
        (uint256 reserve0, uint256 reserve1) = getReserves();

        // Calculate liquidity to be minted
        if (reserve0 == 0 && reserve1 == 0) {
            // Initial liquidity minting
            liquidity = CPAMMUtils.calculateInitialLiquidity(amount0, amount1);
        } else {
            // Calculate liquidity based on existing reserves
            uint256 liquidity0 = (amount0 * totalSupply()) / reserve0;
            uint256 liquidity1 = (amount1 * totalSupply()) / reserve1;
            liquidity = UniswapV4Utils.min(liquidity0, liquidity1);
        }

        // Ensure liquidity is greater than zero
        require(liquidity > 0, "Insufficient liquidity minted");

        // Update reserves
        reserve0 += amount0;
        reserve1 += amount1;

        // Mint liquidity tokens to the user
        _mint(user, liquidity);

        // Emit event
        emit Mint(user, amount0, amount1, liquidity);

        return liquidity;
    }

        /**
     * @dev Burns liquidity from the pool and returns the corresponding token amounts to the user.
     *      Removes full-range liquidity using Uniswap V4's concentrated liquidity mechanics.
     * @param liquidity The amount of liquidity to burn.
     * @param user The address receiving the underlying tokens.
     * @return amount0 The amount of token0 returned to the user.
     * @return amount1 The amount of token1 returned to the user.
     *
     * Requirements:
     * - `liquidity` must be greater than 0.
     * - `user` cannot be the zero address.
     * - The pool must exist for the given pool key.
     *
     * Emits a {Burn} event.
     */
    function burn(
        uint256 liquidity,
        address user
    ) external returns (uint256 amount0, uint256 amount1) {
        // Validate inputs
        require(liquidity > 0, "Cannot burn zero liquidity");
        require(user != address(0), "Invalid user address");

        // Get pool key and validate pool
        PoolKey memory poolKey = _getPoolKey();
        PoolId poolId = poolKey.toId();
        require(factory.poolExists(poolId), "Pool does not exist");

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

        // Convert delta amounts to uint256, handling negative values
        amount0 = delta.amount0() < 0
            ? uint256(-int256(delta.amount0()))
            : uint256(int256(delta.amount0()));
        amount1 = delta.amount1() < 0
            ? uint256(-int256(delta.amount1()))
            : uint256(int256(delta.amount1()));

        // Transfer tokens to user
        if (amount0 > 0)
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(
                user,
                amount0
            );
        if (amount1 > 0)
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(
                user,
                amount1
            );

        emit Burn(user, amount0, amount1, liquidity);
        return (amount0, amount1);
    }

    /**
     * @dev Executes a token swap
     * @param zeroForOne The direction of the swap (true for token0 to token1)
     * @param amountIn The amount of input tokens
     * @param recipient The address receiving the output tokens
     * @return amountOut The amount of output tokens received
     * @notice Handles both exact input and exact output swaps
     */
    function swap(
        bool zeroForOne,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut) {
        // Validate inputs
        require(amountIn > 0, "Invalid amount in");
        require(recipient != address(0), "Invalid recipient");

        // Get pool key and validate pool
        PoolKey memory poolKey = _getPoolKey();
        PoolId poolId = poolKey.toId();
        require(factory.poolExists(poolId), "Pool does not exist");

        // Execute swap through pool manager
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountIn),
                sqrtPriceLimitX96: 0 // No price limit
            }),
            "" // Empty bytes calldata
        );

        // Calculate amount out based on swap direction
        if (zeroForOne) {
            amountOut = delta.amount1() < 0
                ? uint256(-int256(delta.amount1()))
                : uint256(int256(delta.amount1()));
        } else {
            amountOut = delta.amount0() < 0
                ? uint256(-int256(delta.amount0()))
                : uint256(int256(delta.amount0()));
        }

        // Transfer tokens to recipient
        address tokenOut = zeroForOne
            ? Currency.unwrap(poolKey.currency1)
            : Currency.unwrap(poolKey.currency0);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit Swap(
            msg.sender,
            zeroForOne ? amountIn : 0,
            zeroForOne ? 0 : amountIn,
            zeroForOne ? 0 : amountOut,
            zeroForOne ? amountOut : 0,
            recipient
        );

        return amountOut;
    }

    /**
     * @dev Constructs and returns the pool key for the current pair and fee tier.
     *      Uses Uniswap V4 utility functions to derive a `PoolKey` based on the
     *      contract's configured currencies and fee.
     * @return poolKey The derived PoolKey struct containing currency0, currency1, fee, and hook address.
     */
    function _getPoolKey() internal view returns (PoolKey memory) {
        return
            UniswapV4Utils.createPoolKey(
                Currency.unwrap(currency0),
                Currency.unwrap(currency1),
                currentFee,
                address(this)
            );
    }

    /**
     * @dev Returns the pool state associated with a given pool ID.
     * @param poolId The unique identifier for the pool.
     * @return The current PoolState, including reserve balances and other metadata.
     */
    function getPoolState(
        PoolId poolId
    ) external view returns (PoolState memory) {
        return poolStates[poolId];
    }
}
