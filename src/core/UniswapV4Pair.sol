// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICPAMMFactory} from "../Interfaces/ICPAMMFactory.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {UniswapV4Utils} from "../lib/UniswapV4Utils.sol";
import {CPAMMUtils} from "../lib/CPAMMUtils.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Slot0} from "@uniswap/v4-core/src/types/Slot0.sol";

/**
 * @title UniswapV4Pair
 * @notice ERC20 token representing liquidity provider shares in a Uniswap V4 pool
 * @dev Implements core AMM functionality including mint/burn of LP tokens and swaps
 * 
 * Key Features:
 * - ERC20 compliant LP token representing pool shares
 * - Mint/burn functionality for liquidity management
 * - Swap functionality between token pairs
 * - Reentrancy protection for all state-changing operations
 * - Router-controlled LP token minting/burning
 * 
 * Security Considerations:
 * - All state-changing functions are non-reentrant
 * - Router-only access for mintLP/burnLP functions
 * - Strict input validation for all operations
 */
contract UniswapV4Pair is ReentrancyGuard, IERC20 {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;
    using UniswapV4Utils for uint256;
    using UniswapV4Utils for uint160;
    using CPAMMUtils for uint256;
    using CPAMMUtils for uint160;
    using CPAMMUtils for PoolId;
    using UniswapV4Utils for PoolKey;

    // State variables
    IPoolManager public immutable poolManager; // Uniswap V4 PoolManager contract
    PoolKey public poolKey; // Pool configuration parameters
    PoolId public immutable poolId; // Unique identifier for the pool
    IERC20 public immutable token0; // First token in the pair
    IERC20 public immutable token1; // Second token in the pair
    address public immutable factory;   // Factory contract that created this pool
    address public immutable router; // Router contract with mint/burn privileges

    // ERC20 state
    mapping(address => uint256) private _balances; // LP token balances
    uint256 private _totalSupply;   // Total LP tokens in circulation
    mapping(address => mapping(address => uint256)) private _allowances; // Token allowances   

    // Custom errors
    error InvalidFactory(address factory); // Invalid factory address
    error InvalidRecipient(address recipient); // Invalid recipient address
    error InvalidPool(PoolId poolId); // Invalid pool configuration
    error InsufficientLiquidityMinted(uint256 provided, uint256 minimum); // Insufficient liquidity
    error InvalidSwapAmount(uint256 amount0Out, uint256 amount1Out); // Invalid swap amounts
    error InvalidHook(address hook); // Invalid hook address
    error InsufficientLiquidity(uint256 reserve0, uint256 reserve1, uint256 minimum); // Insufficient reserves
    error LiquidityOverflow(uint256 liquidity); // Liquidity amount too large
    error OnlyRouter(address caller); // Unauthorized router access

    // Events
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint256 reserve0, uint256 reserve1);
    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96);
    event LiquidityAdded(
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );
    event LiquidityChanged(PoolId indexed poolId, int256 liquidityDelta);

    /**
     * @notice Constructs the UniswapV4Pair contract
     * @param _poolManager Uniswap V4 PoolManager contract address
     * @param _poolKey Pool configuration parameters
     * @param _factory Factory contract address
     * @param _router Router contract address
     * @dev Validates factory and hook addresses during construction
     */
    constructor(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        address _factory,
        address _router 
    ) {
        if (_factory == address(0)) revert InvalidFactory(_factory);
        if (!ICPAMMFactory(_factory).isHookValid(address(_poolKey.hooks))) {
            revert InvalidHook(address(_poolKey.hooks));
        }
        factory = _factory;
        router = _router; 
        poolManager = _poolManager;
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        token0 = IERC20(Currency.unwrap(_poolKey.currency0));
        token1 = IERC20(Currency.unwrap(_poolKey.currency1));
    }

    /**
     * @dev Modifier to validate pool ID
     * @param targetPoolId Pool ID to validate
     */
    modifier whenPoolValid(PoolId targetPoolId) {
        if (!CPAMMUtils.validatePool(factory, targetPoolId))
            revert InvalidPool(targetPoolId);
        _;
    }

    // Core functions

    /**
     * @notice Mints new LP tokens representing pool shares
     * @param to Address to receive the minted LP tokens
     * @return liquidity Amount of LP tokens minted
     * @dev Non-reentrant and validates pool state
     */
    function mint(
        address to
    ) external nonReentrant whenPoolValid(poolId) returns (uint256 liquidity) {
        if (to == address(0)) revert InvalidRecipient(to);

        // 1) fetch current reserves
        (uint256 reserve0_, uint256 reserve1_) = getReserves();

        // 2) call into the poolManager (we assume router already sent tokens in)
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: UniswapV4Utils.MIN_TICK,
                tickUpper: UniswapV4Utils.MAX_TICK,
                liquidityDelta: int256(
                    CPAMMUtils.calculateInitialLiquidity(reserve0_, reserve1_)
                ),
                salt: bytes32(0)
            }),
            ""
        );

        // 3) pull out the signed deltas
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // 4) compute absolute magnitudes
        int128 abs0 = amount0 < 0 ? -amount0 : amount0;
        int128 abs1 = amount1 < 0 ? -amount1 : amount1;

        // 5) take the larger one
        uint128 chosen = uint128(abs0 > abs1 ? abs0 : abs1);

        liquidity = uint256(chosen);
        if (liquidity == 0) {
            revert InsufficientLiquidityMinted(0, CPAMMUtils.MIN_LIQUIDITY);
        }
        if (liquidity > uint256(type(int256).max)) {
            revert LiquidityOverflow(liquidity);
        }

        // 6) mint the LP tokens
        _totalSupply += liquidity;
        _balances[to] += liquidity;

        // 7) emit compatibility events
        emit LiquidityAdded(to, reserve0_, reserve1_, liquidity);
        emit Mint(msg.sender, reserve0_, reserve1_);

        return liquidity;
    }

    /**
     * @notice Internal function to burn LP tokens
     * @param from Address whose tokens will be burned
     * @param amount Amount of LP tokens to burn
     */
    function burn(address from, uint256 amount) internal {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _totalSupply -= amount;
    }

    /**
     * @notice Executes a token swap
     * @param amount0Out Amount of token0 to output
     * @param amount1Out Amount of token1 to output
     * @param to Address to receive the output tokens
     * @dev Non-reentrant and validates swap amounts
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external nonReentrant {
        if (amount0Out == 0 && amount1Out == 0)
            revert InvalidSwapAmount(amount0Out, amount1Out);
        if (to == address(0)) revert InvalidRecipient(to);

        (uint256 reserve0, uint256 reserve1) = getReserves();
        if (amount0Out >= reserve0 || amount1Out >= reserve1) {
            revert InsufficientLiquidity(
                reserve0,
                reserve1,
                CPAMMUtils.MIN_LIQUIDITY
            );
        }

        // Perform swap through pool manager
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: amount0Out > 0,
                amountSpecified: amount0Out > 0
                    ? int256(amount0Out)
                    : int256(amount1Out),
                sqrtPriceLimitX96: 0 // No price limit
            }),
            "" // Empty bytes calldata
        );

        emit Swap(
            msg.sender,
            delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0,
            delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0,
            amount0Out,
            amount1Out,
            to
        );
    }

    // View functions

    /**
     * @notice Gets the current reserves of the pool
     * @return reserve0 Reserve amount of token0
     * @return reserve1 Reserve amount of token1
     */
    function getReserves()
        public
        view
        returns (uint256 reserve0, uint256 reserve1)
    {
        bytes32 slot = keccak256(abi.encode(poolKey, "Slot0"));

        // First get the bytes32 value
        bytes32 value = poolManager.extsload(slot);

        // Convert the bytes32 to uint160 by taking the first 160 bits
        uint160 sqrtPriceX96 = uint160(uint256(value));

        // Calculate reserves using the sqrtPriceX96
        return CPAMMUtils.calculateReservesFromSqrtPrice(sqrtPriceX96);
    }

    /**
     * @notice Gets the LP token balance of an account
     * @param account Address to query
     * @return balance LP token balance
     */
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /**
     * @notice Gets the total supply of LP tokens
     * @return totalSupply Total LP tokens in circulation
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    // ERC20 functions

    /**
     * @notice Approves a spender to transfer LP tokens
     * @param spender Address to approve
     * @param amount Amount to approve
     * @return success Always returns true
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Transfers LP tokens
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success Always returns true
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfers LP tokens from an approved address
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success Always returns true
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Gets the allowance for a spender
     * @param owner Token owner
     * @param spender Approved spender
     * @return allowance Approved amount
     */
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // Router-only functions

    /**
     * @notice Mints LP tokens (router only)
     * @param to Recipient address
     * @param liquidity Amount to mint
     * @dev Only callable by the router
     */
    function mintLP(address to, uint256 liquidity) external {
        if (msg.sender != router) revert OnlyRouter(msg.sender);
        require(to != address(0), "Invalid recipient");
        require(liquidity > 0, "Insufficient liquidity");
        _totalSupply += liquidity;
        _balances[to] += liquidity;
        emit Transfer(address(0), to, liquidity);
    }

    /**
     * @notice Burns LP tokens (router only)
     * @param from Address whose tokens will be burned
     * @param liquidity Amount to burn
     * @dev Only callable by the router
     */
    function burnLP(address from, uint256 liquidity) external {
        if (msg.sender != router) revert OnlyRouter(msg.sender);
        require(liquidity > 0, "Insufficient liquidity");

        // Burn the tokens that were just pulled into the pair contract.
        uint256 held = _balances[address(this)];
        require(held >= liquidity, "Insufficient pair balance");
        _balances[address(this)] = held - liquidity;
        _totalSupply -= liquidity;
        // Standard ERC‑20 Burn event from the pair’s own balance
        emit Transfer(address(this), address(0), liquidity);
    }

    // Internal helper functions

    /**
     * @dev Internal approval function
     * @param owner Token owner
     * @param spender Approved spender
     * @param amount Approved amount
     */
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from zero address");
        require(spender != address(0), "ERC20: approve to zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Internal allowance spending function
     * @param owner Token owner
     * @param spender Approved spender
     * @param amount Amount to spend
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            require(
                currentAllowance >= amount,
                "ERC20: insufficient allowance"
            );
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Internal transfer function
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from zero address");
        require(to != address(0), "ERC20: transfer to zero address");
        require(_balances[from] >= amount, "ERC20: insufficient balance");

        unchecked {
            _balances[from] -= amount;
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }
}
