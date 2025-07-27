// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract PoolModifyLiquidityTest {
    IPoolManager public immutable manager;
    
    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function modifyLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes memory hookData
    ) external returns (BalanceDelta) {
        (BalanceDelta delta, ) = manager.modifyLiquidity(
            key, 
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            hookData
        );

        // Handle token0 transfers
        if (delta.amount0() > 0) {
            manager.take(key.currency0, msg.sender, uint256(uint128(delta.amount0())));
        } else if (delta.amount0() < 0) {
            key.currency0.transfer(address(manager), uint256(uint128(-delta.amount0())));
        }

        // Handle token1 transfers
        if (delta.amount1() > 0) {
            manager.take(key.currency1, msg.sender, uint256(uint128(delta.amount1())));
        } else if (delta.amount1() < 0) {
            key.currency1.transfer(address(manager), uint256(uint128(-delta.amount1())));
        }

        return delta;
    }
}
