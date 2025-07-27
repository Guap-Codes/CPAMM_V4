// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockPoolManager is IPoolManager {
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    // Mapping to store pool addresses
    mapping(bytes32 => address) private _pools;
    uint256 private _poolCount;

    // Track token balances for each currency
    mapping(address => uint256) public tokenBalances;

    // Temporary storage for expected BalanceDelta
    mapping(PoolId => BalanceDelta) public nextModifyLiquidityCallerDelta;
    mapping(PoolId => BalanceDelta) public nextSwapDelta;

    // Reserve tracking
    mapping(PoolId => uint256) public reserve0;
    mapping(PoolId => uint256) public reserve1;

    /**
     * @notice Get pool address for a given PoolKey
     * @param key The pool key identifying the pool
     * @return The address of the mock pool
     */
    function pools(PoolKey calldata key) external view returns (address) {
        return _pools[_keyHash(key)];
    }

    /**
     * @notice Initialize a new mock pool
     * @param key The pool configuration key
     * @param sqrtPriceX96 The initial square root price (unused in mock)
     * @return tick Always returns 0 in mock implementation
     */
    function initialize(
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external override returns (int24 tick) {
        bytes32 keyHash = _keyHash(key);
        address poolAddress = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(address(this), _poolCount++))
                )
            )
        );
        _pools[keyHash] = poolAddress;
        return 0;
    }

    /**
     * @notice Set expected delta for next modifyLiquidity call
     * @param poolId The pool ID to configure
     * @param amount0 Delta for token0
     * @param amount1 Delta for token1
     */
    function setNextModifyLiquidityCallerDelta(
        PoolId poolId,
        int128 amount0,
        int128 amount1
    ) external {
        nextModifyLiquidityCallerDelta[poolId] = toBalanceDelta(
            amount0,
            amount1
        );
    }

    /**
     * @notice Set expected delta for next swap call
     * @param poolId The pool ID to configure
     * @param amount0 Delta for token0
     * @param amount1 Delta for token1
     */
    function setNextSwapDelta(
        PoolId poolId,
        int128 amount0,
        int128 amount1
    ) external {
        nextSwapDelta[poolId] = toBalanceDelta(amount0, amount1);
    }

    /**
     * @notice Mock implementation of modifyLiquidity
     * @param key The pool configuration key
     * @param params Liquidity modification parameters
     * @param hookData Additional data for hooks (unused in mock)
     * @return callerDelta The pre-configured balance delta
     * @return feesAccrued Always returns 0 in mock
     */
    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        external
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId poolId = key.toId();
        feesAccrued = BalanceDelta.wrap(0);
        callerDelta = nextModifyLiquidityCallerDelta[poolId];
        nextModifyLiquidityCallerDelta[poolId] = BalanceDeltaLibrary.ZERO_DELTA;

        // Update token balances and reserves
        if (callerDelta.amount0() < 0) {
            uint256 amount0 = uint256(uint128(-callerDelta.amount0()));
            tokenBalances[Currency.unwrap(key.currency0)] += amount0;
            reserve0[poolId] += amount0;
        } else if (callerDelta.amount0() > 0) {
            uint256 amount0 = uint256(uint128(callerDelta.amount0()));
            require(
                tokenBalances[Currency.unwrap(key.currency0)] >= amount0,
                "Insufficient token0 balance"
            );
            tokenBalances[Currency.unwrap(key.currency0)] -= amount0;
            reserve0[poolId] = reserve0[poolId] >= amount0
                ? reserve0[poolId] - amount0
                : 0;
            IERC20(Currency.unwrap(key.currency0)).safeTransfer(
                msg.sender,
                amount0
            );
        }

        if (callerDelta.amount1() < 0) {
            uint256 amount1 = uint256(uint128(-callerDelta.amount1()));
            tokenBalances[Currency.unwrap(key.currency1)] += amount1;
            reserve1[poolId] += amount1;
        } else if (callerDelta.amount1() > 0) {
            uint256 amount1 = uint256(uint128(callerDelta.amount1()));
            require(
                tokenBalances[Currency.unwrap(key.currency1)] >= amount1,
                "Insufficient token1 balance"
            );
            tokenBalances[Currency.unwrap(key.currency1)] -= amount1;
            reserve1[poolId] = reserve1[poolId] >= amount1
                ? reserve1[poolId] - amount1
                : 0;
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(
                msg.sender,
                amount1
            );
        }

        // Calculate liquidity for new pool
        if (
            reserve0[poolId] > 0 &&
            reserve1[poolId] > 0 &&
            params.liquidityDelta > 0
        ) {
            uint256 liquidity = Math.sqrt(
                uint256(uint128(-callerDelta.amount0())) *
                    uint256(uint128(-callerDelta.amount1()))
            ) - 1000; // MIN_LIQUIDITY
            if (params.liquidityDelta != int256(liquidity)) {
                callerDelta = toBalanceDelta(
                    int128(-int256(liquidity)),
                    int128(-int256(liquidity))
                );
            }
        }

        if (address(key.hooks) != address(0)) {
            IHooks(key.hooks).afterAddLiquidity(
                msg.sender,
                key,
                params,
                callerDelta,
                feesAccrued,
                hookData
            );
        }

        return (callerDelta, feesAccrued);
    }

    /**
     * @notice Mock implementation of swap
     * @param key The pool configuration key
     * @param params Swap parameters (largely unused in mock)
     * @param hookData Additional data for hooks
     * @return swapDelta The pre-configured balance delta
     */
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (BalanceDelta) {
        PoolId poolId = key.toId();
        BalanceDelta swapDelta = nextSwapDelta[poolId];
        nextSwapDelta[poolId] = BalanceDeltaLibrary.ZERO_DELTA;

        // Update reserves safely
        int256 newReserve0 = int256(reserve0[poolId]) + swapDelta.amount0();
        require(newReserve0 >= 0, "Insufficient reserve0");
        reserve0[poolId] = uint256(newReserve0);

        int256 newReserve1 = int256(reserve1[poolId]) + swapDelta.amount1();
        require(newReserve1 >= 0, "Insufficient reserve1");
        reserve1[poolId] = uint256(newReserve1);

        if (address(key.hooks) != address(0)) {
            IHooks(key.hooks).afterSwap(
                msg.sender,
                key,
                params,
                swapDelta,
                hookData
            );
        }
        return swapDelta;
    }

    function donate(
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    // IERC6909Claims (unchanged)
    function balanceOf(
        address,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function allowance(
        address,
        address,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function isOperator(
        address,
        address
    ) external pure override returns (bool) {
        return false;
    }

    function transfer(
        address,
        uint256,
        uint256
    ) external pure override returns (bool) {
        return true;
    }

    function transferFrom(
        address,
        address,
        uint256,
        uint256
    ) external pure override returns (bool) {
        return true;
    }

    /**
     * @notice Transfer tokens from mock manager to recipient
     * @param token The token to transfer
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function transferTokens(
        address token,
        address to,
        uint256 amount
    ) external {
        IERC20(token).transfer(to, amount);
    }

    function approve(
        address,
        uint256,
        uint256
    ) external pure override returns (bool) {
        return true;
    }

    function setOperator(address, bool) external pure override returns (bool) {
        return true;
    }

    // IProtocolFees (unchanged)
    function protocolFeesAccrued(
        Currency
    ) external pure override returns (uint256) {
        return 0;
    }

    function setProtocolFee(PoolKey calldata, uint24) external pure override {}

    function setProtocolFeeController(address) external pure override {}

    function protocolFeeController() external pure override returns (address) {
        return address(0);
    }

    function collectProtocolFees(
        address,
        Currency,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    // IExtsload (unchanged)
    function extsload(bytes32) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function extsload(
        bytes32,
        uint256 n
    ) external pure override returns (bytes32[] memory) {
        return new bytes32[](n);
    }

    function extsload(
        bytes32[] calldata keys
    ) external pure override returns (bytes32[] memory) {
        return new bytes32[](keys.length);
    }

    // IExttload (unchanged)
    function exttload(bytes32) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function exttload(
        bytes32[] calldata keys
    ) external pure override returns (bytes32[] memory) {
        return new bytes32[](keys.length);
    }

    function unlock(
        bytes calldata
    ) external pure override returns (bytes memory) {
        return "";
    }

    function settle() external payable override returns (uint256) {
        return 0;
    }

    function settleFor(address) external payable override returns (uint256) {
        return 0;
    }

  
    function mint(address, uint256, uint256) external pure override {}

    function burn(address, uint256, uint256) external pure override {}

    function sync(Currency) external pure override {}

    function clear(Currency, uint256) external pure override {}

    function updateDynamicLPFee(
        PoolKey memory,
        uint24
    ) external pure override {}


    /**
     * @notice Take tokens from mock manager (used in testing)
     * @param currency The currency to take
     * @param to The recipient address
     * @param amount The amount to take
     */
    function take(Currency currency, address to, uint256 amount) external override {
        require(
            tokenBalances[Currency.unwrap(currency)] >= amount,
            "Insufficient balance in MockPoolManager"
        );
        tokenBalances[Currency.unwrap(currency)] -= amount;
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }

    /**
     * @dev Internal function to compute pool key hash
     * @param key The pool configuration key
     * @return The computed hash of the pool key
     */    
    function _keyHash(PoolKey memory key) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    key.currency0,
                    key.currency1,
                    key.fee,
                    key.tickSpacing,
                    key.hooks
                )
            );
    }

    /**
     * @notice Set mock reserves for a pool
     * @param poolId The pool ID to configure
     * @param res0 New reserve0 value
     * @param res1 New reserve1 value
     */
    function setReserves(PoolId poolId, uint256 res0, uint256 res1) external {
        reserve0[poolId] = res0;
        reserve1[poolId] = res1;
    }

    /**
     * @notice Get mock reserves for a pool
     * @param poolId The pool ID to query
     * @return reserve0 Current reserve0 value
     * @return reserve1 Current reserve1 value
     */
    function getReserves(
        PoolId poolId
    ) external view returns (uint256, uint256) {
        return (reserve0[poolId], reserve1[poolId]);
    }
}
