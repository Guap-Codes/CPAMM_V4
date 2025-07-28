// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ICPAMMFactory} from "../Interfaces/ICPAMMFactory.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

library CPAMMUtils {
    using FixedPointMathLib for uint256;

    // Constants
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant MIN_LIQUIDITY = 1000;
    uint256 internal constant MAX_FEE = 100000; // 10%
    uint24 internal constant DEFAULT_FEE = 3000; // 0.3% default fee
    uint256 internal constant DEFAULT_SLIPPAGE = 0.01e18; // 1%
    uint24 constant DEFAULT_PROTOCOL_FEE = 500; // 0.05% default protocol fee

    // Add error definitions
    error InsufficientAmount(uint256 provided, uint256 minimum);
    error InsufficientLiquidity(
        uint256 reserveA,
        uint256 reserveB,
        uint256 minLiquidity
    );

    // Core calculation functions
    function calculateReservesFromSqrtPrice(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 reserve0, uint256 reserve1) {
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        price = price >> 192;
        return (PRECISION, price.mulWadDown(PRECISION));
    }

   function calculateInitialLiquidity(
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256) {
        uint256 product = amount0 * amount1;
        uint256 sqrtProduct = product.sqrt();
        
        // Prevent underflow by checking against MIN_LIQUIDITY
        if (sqrtProduct <= MIN_LIQUIDITY) {
            return 0;
        }
        return sqrtProduct - MIN_LIQUIDITY;
    }

    // Validation functions
    function hasLiquidity(
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (bool) {
        return amount0 >= MIN_LIQUIDITY && amount1 >= MIN_LIQUIDITY;
    }

    function validatePool(
        address factory,
        PoolId poolId
    ) internal view returns (bool) {
        // Get the factory interface
        ICPAMMFactory cpammFactory = ICPAMMFactory(factory);

        // Check if pool exists and is valid
        try cpammFactory.validatePool(poolId) returns (bool isValid) {
            return isValid;
        } catch {
            return false;
        }
    }

    // Additional functions needed based on usage in CPAMM.sol and UniswapV4Pair.sol:
    function calculateK(
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256) {
        return reserve0 * reserve1;
    }

    function validateK(
        uint256 oldK,
        uint256 newK
    ) internal pure returns (bool) {
        return newK >= oldK;
    }

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientAmount(0, 0);
        if (reserveA == 0 || reserveB == 0)
            revert InsufficientLiquidity(reserveA, reserveB, MIN_LIQUIDITY);
        return (amountA * reserveB) / reserveA;
    }
}
