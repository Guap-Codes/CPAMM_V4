// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CPAMM} from "../../src/core/CPAMM.sol";
import {CPAMMFactory} from "../../src/core/CPAMMFactory.sol";
import {CPAMMRouter} from "../../src/periphery/CPAMMRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

abstract contract CPAMMHelpers is Test {
    function _createTestPool(
        CPAMMFactory factory,
        address tokenA,
        address tokenB,
        uint24 fee,
        uint160 sqrtPriceX96
    ) internal returns (PoolId, address) {
        return factory.createPool(tokenA, tokenB, fee, sqrtPriceX96);
    }

    function _addLiquidity(
        address token0,
        address token1,
        address pair,
        uint256 amount0,
        uint256 amount1,
        address user
    ) internal returns (uint256 liquidity) {
        // Transfer tokens to the user
        MockERC20(token0).mint(user, amount0);
        MockERC20(token1).mint(user, amount1);

        // Approve tokens
        vm.startPrank(user);
        MockERC20(token0).approve(pair, amount0);
        MockERC20(token1).approve(pair, amount1);

        // Add liquidity and get the liquidity amount
        liquidity = CPAMM(pair).mint(amount0, amount1, user);
        vm.stopPrank();

        return liquidity;
    }

    function _removeLiquidity(
        address pair,
        uint256 liquidity,
        address user
    ) internal returns (uint256 amount0, uint256 amount1) {
        return CPAMM(pair).burn(liquidity, user);
    }

   /* function _swap(
        address token0,
        address token1,
        address pair,
        bool zeroForOne,
        uint256 amountIn,
        address recipient,
        uint256 expectedMinOut
    ) internal returns (uint256 amountOut) {
        // Mint tokens to the user for swapping
        address tokenIn = zeroForOne ? token0 : token1;
        MockERC20(tokenIn).mint(recipient, amountIn);

        // Approve tokens
        vm.startPrank(recipient);
        MockERC20(tokenIn).approve(pair, amountIn);

        // Execute swap
        amountOut = CPAMM(pair).swap(zeroForOne, amountIn, recipient);

        // Verify minimum output amount
        require(amountOut >= expectedMinOut, "Insufficient output amount");

        vm.stopPrank();
        return amountOut;
    }*/

   
    function setupTokens(
        address user
    ) internal returns (address token0, address token1) {
        // Deploy new mock tokens
        MockERC20 tokenA = new MockERC20("Test Token A", "TKNA", 18);
        MockERC20 tokenB = new MockERC20("Test Token B", "TKNB", 18);

        // Sort tokens by address to maintain consistent ordering
        if (address(tokenA) < address(tokenB)) {
            token0 = address(tokenA);
            token1 = address(tokenB);
        } else {
            token0 = address(tokenB);
            token1 = address(tokenA);
        }

        // Mint initial tokens to user
        MockERC20(token0).mint(user, 1000e18);
        MockERC20(token1).mint(user, 1000e18);
    }

    function createPool(
        CPAMMFactory factory,
        address token0,
        address token1,
        uint24 fee,
        uint160 initialSqrtPrice
    ) internal returns (PoolId poolId, address hookAddr) {
        (poolId, hookAddr) = factory.createPool(
            token0,
            token1,
            fee,
            initialSqrtPrice
        );

        // Verify pool creation
        require(hookAddr != address(0), "Pool creation failed");
        require(factory.getHook(poolId) == hookAddr, "Pool not registered");

        return (poolId, hookAddr);
    }

    /*  function addLiquidity(
        MockERC20 token0,
        MockERC20 token1,
        CPAMMRouter router,
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) internal {
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        token0.approve(address(router), amount0);
        token1.approve(address(router), amount1);

        router.addLiquidity(
            address(token0),
            address(token1),
            amount0,
            amount1,
            0,
            0,
            address(this),
            block.timestamp
        );
    }*/
    function addLiquidity(
        MockERC20 token0,
        MockERC20 token1,
        CPAMMRouter router,
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // Mint & approve
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        token0.approve(address(router), amount0);
        token1.approve(address(router), amount1);

        // Tell the mock what to record on the next modifyLiquidity call
        // router.poolManager() returns the IPoolManager — cast it back to your MockPoolManager
        MockPoolManager pm = MockPoolManager(address(router.poolManager()));
        int128 d0 = -int128(int256(amount0));
        int128 d1 = -int128(int256(amount1));
        pm.setNextModifyLiquidityCallerDelta(poolId, d0, d1);

        // Now actually add liquidity via the router
        router.addLiquidity(
            address(token0),
            address(token1),
            amount0,
            amount1,
            0, // amountAMin
            0, // amountBMin
            address(this),
            block.timestamp
        );
    }

    function createMockPool(
        CPAMMFactory factory,
        uint24 fee,
        uint160 sqrtPrice
    ) internal returns (PoolId) {
        address token0 = address(1);
        address token1 = address(2);

        (PoolId poolId, ) = factory.createPool(token0, token1, fee, sqrtPrice);
        return poolId;
    }

    function createTestPoolWithHook(
        CPAMMFactory factory,
        address tokenA,
        address tokenB,
        uint24 fee,
        uint160 sqrtPriceX96
    ) internal returns (PoolId poolId, address hookAddr) {
        (poolId, hookAddr) = factory.createPool(
            tokenA,
            tokenB,
            fee,
            sqrtPriceX96
        );

        // Verify the hook address is correctly registered
        require(factory.getHook(poolId) == hookAddr, "Hook not registered");
        require(factory.poolExists(poolId), "Pool not created");

        return (poolId, hookAddr);
    }
}
