// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IUniswapV3Pool} from "v1-periphery/lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/**
 * @title IPancakeSwapV3TWAPOracle
 * @notice Interface for PancakeSwap V3 TWAP oracle
 * @dev Provides time-weighted average price from PancakeSwap V3 pools
 */
interface IPancakeSwapV3TWAPOracle {
    /**
     * @notice Emitted when the TWAP period is updated
     * @param previousPeriod Previous TWAP period in seconds
     * @param newPeriod New TWAP period in seconds
     */
    event TwapPeriodUpdated(uint32 previousPeriod, uint32 newPeriod);

    /**
     * @notice Emitted when the pool address is updated
     * @param previousPool Previous pool address
     * @param newPool New pool address
     */
    event PoolUpdated(address indexed previousPool, address indexed newPool);

    /**
     * @notice Returns the current TWAP price of token0 in terms of token1
     * @dev Returns how many token1 per 1 token0 (e.g., USDT per 1 OVL)
     * @dev Price is normalized to 1e18 (WAD precision)
     * @dev Reverts if insufficient oracle history (cardinality too low)
     * @return price The TWAP price scaled to 1e18
     */
    function getPrice() external view returns (uint256 price);

    /**
     * @notice Returns the PancakeSwap V3 pool contract
     * @return The pool contract used for TWAP
     */
    function pool() external view returns (IUniswapV3Pool);

    /**
     * @notice Returns the TWAP period in seconds
     * @return period The time period for TWAP calculation
     */
    function twapPeriod() external view returns (uint32 period);

    /**
     * @notice Checks if the pool has sufficient cardinality for TWAP
     * @return hasCardinality True if pool has enough observations
     */
    function checkCardinality() external view returns (bool hasCardinality);

    /**
     * @notice Returns the minimum required cardinality for the TWAP period
     * @return minCardinality The minimum number of observations needed
     */
    function getMinCardinality() external view returns (uint16 minCardinality);
}
