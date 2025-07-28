// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICPAMMFactory } from "../Interfaces/ICPAMMFactory.sol";
import { ICPAMMHook } from "../Interfaces/ICPAMMHook.sol";
import { CPAMMUtils } from "../lib/CPAMMUtils.sol";

contract CPAMMOracle {
    using CPAMMUtils for uint256;
    using CPAMMUtils for PoolId;

    // State variables
    ICPAMMFactory public immutable factory;
    uint256 public constant PERIOD = 1 hours;

    /**
     * @dev Struct representing a single price/reserve observation
     * @param timestamp Block timestamp when observation was recorded
     * @param price Price of token1 in terms of token0 (scaled by 1e18)
     * @param reserve0 Reserve amount of token0 at observation time
     * @param reserve1 Reserve amount of token1 at observation time
     */
    struct Observation {
        uint256 timestamp;
        uint256 price;
        uint256 reserve0;
        uint256 reserve1;
    }

    // Price history mapping: poolId => timestamp => Observation
    mapping(PoolId => mapping(uint256 => Observation)) public observations;

    // Latest observation timestamp for each pool
    mapping(PoolId => uint256) public lastObservation;

    // Events
    event PriceObservation(PoolId indexed poolId, uint256 price, uint256 timestamp);
    event ReservesObservation(PoolId indexed poolId, uint256 reserve0, uint256 reserve1, uint256 timestamp);

    // Errors
    error PoolDoesNotExist(PoolId poolId);
    error StalePrice(uint256 timestamp, uint256 currentTime);
    error NoObservations(PoolId poolId);
    error InvalidPeriod(uint256 provided, uint256 required);

    /**
     * @notice Initializes the oracle contract
     * @param _factory Address of the CPAMM factory contract
     */
    constructor(ICPAMMFactory _factory) {
        factory = _factory;
    }

    /**
     * @notice Updates the price and reserve observation for a pool
     * @dev Stores observations in 1-hour buckets. Anyone can call this to update the oracle.
     * @param poolId The ID of the pool to update
     * @return price The current price that was recorded (token1 per token0, scaled by 1e18)
     */
    function updatePrice(PoolId poolId) external returns (uint256 price) {
        if (!factory.poolExists(poolId)) revert PoolDoesNotExist(poolId);

        ICPAMMHook hook = ICPAMMHook(factory.getHook(poolId));
        (uint256 reserve0_, uint256 reserve1_) = hook.getReserves(poolId);

        uint256 currentPrice = reserve0_ > 0 ? (reserve1_ * 1e18) / reserve0_ : 0;
        uint256 nowTs = block.timestamp;
        uint256 bucket = (nowTs / PERIOD) * PERIOD;

        observations[poolId][bucket] =
            Observation({ timestamp: nowTs, price: currentPrice, reserve0: reserve0_, reserve1: reserve1_ });

        // lastObservation now stores the bucket key, not the raw timestamp
        lastObservation[poolId] = bucket;

        emit PriceObservation(poolId, currentPrice, nowTs);
        emit ReservesObservation(poolId, reserve0_, reserve1_, nowTs);
        return currentPrice;
    }

    /**
     * @notice Gets the historical price for a pool at a specific time in the past
     * @dev Looks up the nearest available observation within the allowed period
     * @param poolId The ID of the pool to query
     * @param secondsAgo How far back to look for the price (must be <= PERIOD)
     * @return price The historical price (token1 per token0, scaled by 1e18)
     */
    function consult(PoolId poolId, uint256 secondsAgo) external view returns (uint256 price) {
        if (!factory.poolExists(poolId)) revert PoolDoesNotExist(poolId);
        if (secondsAgo == 0 || secondsAgo > PERIOD) {
            revert InvalidPeriod(secondsAgo, PERIOD);
        }

        // 3) Staleness: pull the **real** timestamp out of the latest bucket’s Observation
        uint256 lastBucket = lastObservation[poolId];
        Observation memory lastObs = observations[poolId][lastBucket];

        if (lastObs.timestamp == 0) revert NoObservations(poolId);

        if (block.timestamp - lastObs.timestamp > secondsAgo) {
            revert StalePrice(lastObs.timestamp, block.timestamp);
        }

        uint256 target = block.timestamp - secondsAgo;
        uint256 bucket = (target / PERIOD) * PERIOD;

        Observation memory obs = observations[poolId][bucket];
        if (obs.timestamp == 0) {
            for (uint256 i = 1; i <= 5; i++) {
                uint256 prev = bucket - PERIOD * i;
                obs = observations[poolId][prev];
                if (obs.timestamp != 0) return obs.price;
            }
            revert NoObservations(poolId);
        }
        return obs.price;
    }

    /**
     * @notice Gets the latest reserve observation for a pool
     * @dev Falls back to hook's current reserves if no oracle observation exists
     * @param poolId The ID of the pool to query
     * @return reserve0_ Reserve amount of token0
     * @return reserve1_ Reserve amount of token1
     * @return ts Timestamp of the observation (current block time if falling back to hook)
     */
    function getReserves(PoolId poolId) external view returns (uint256 reserve0_, uint256 reserve1_, uint256 ts) {
        if (!factory.poolExists(poolId)) revert PoolDoesNotExist(poolId);

        uint256 lastBucket = lastObservation[poolId];
        Observation memory obs = observations[poolId][lastBucket];

        if (obs.timestamp == 0) {
            // no on‐chain observation yet → fall back to the hook
            ICPAMMHook hook = ICPAMMHook(factory.getHook(poolId));
            (reserve0_, reserve1_) = hook.getReserves(poolId);
            return (reserve0_, reserve1_, block.timestamp);
        }

        return (obs.reserve0, obs.reserve1, obs.timestamp);
    }
}
