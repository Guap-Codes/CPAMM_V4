// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CPAMMUtils} from "./CPAMMUtils.sol";

library UniswapV4Utils {
    // Constants
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    int24 internal constant DEFAULT_TICK_SPACING = 60;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint24 internal constant MAX_FEE = 100000; // 10% max fee

    // Errors
    error InvalidSqrtPrice(uint160 provided, uint160 min, uint160 max);
    error InvalidTokens(address tokenA, address tokenB);
    error InvalidFee(uint24 fee, uint24 maxFee);

    function createPoolKey(address token0, address token1, uint24 fee, address hook)
        public
        pure
        returns (PoolKey memory)
    {
        if (token0 == token1) revert InvalidTokens(token0, token1);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function validateSqrtPrice(uint160 sqrtPriceX96) public pure returns (uint160) {
        if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 > MAX_SQRT_RATIO) {
            revert InvalidSqrtPrice(sqrtPriceX96, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        }
        return sqrtPriceX96;
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert InvalidTokens(tokenA, tokenB);
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert InvalidTokens(token0, address(0));
        return (token0, token1);
    }

    // Math utilities moved from UniswapV4Pair
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    // Add validation wrapper
    function wrapCurrency(address token) internal pure returns (Currency) {
        if (token == address(0)) revert InvalidTokens(token, address(0));
        return Currency.wrap(token);
    }

    function validateFee(uint24 fee) public pure returns (uint24) {
        if (fee > MAX_FEE) revert InvalidFee(fee, MAX_FEE);
        return fee;
    }

    function validatePool(PoolKey memory _key) public pure returns (bool) {
        // Basic validation of pool key components
        if (_key.currency0 == _key.currency1) return false;
        if (address(_key.hooks) == address(0)) return false;
        if (_key.fee > MAX_FEE) return false;
        
        // Validate tick spacing
        if (_key.tickSpacing <= 0 || _key.tickSpacing > MAX_TICK - MIN_TICK) return false;
        
        return true;
    }
}
