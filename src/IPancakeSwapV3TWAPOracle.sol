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
     * @notice Returns the TWAP price of token0 in terms of token1 over the specified period
     * @dev Returns how many token1 per 1 token0 (e.g., USDT per 1 OVL)
     * @dev Price is normalized to 1e18 (WAD precision)
     * @dev Reverts if insufficient oracle history (cardinality too low)
     * @param twapPeriod The TWAP period in seconds (e.g., 1800 for 30 minutes)
     * @return price The TWAP price scaled to 1e18
     */
    function getPrice(uint32 twapPeriod) external view returns (uint256 price);

    /**
     * @notice Returns the PancakeSwap V3 pool contract
     * @return The pool contract used for TWAP
     */
    function pool() external view returns (IUniswapV3Pool);

    /**
     * @notice Checks if the pool has sufficient cardinality for the given TWAP period
     * @param twapPeriod The TWAP period in seconds to check
     * @return hasCardinality True if pool has enough observations for the period
     */
    function checkCardinality(uint32 twapPeriod) external view returns (bool hasCardinality);

    /**
     * @notice Returns the minimum required cardinality for any TWAP period
     * @return minCardinality The minimum number of observations needed
     */
    function getMinCardinality() external view returns (uint16 minCardinality);

    /**
     * @notice Returns the current spot price from the pool (non-TWAP)
     * @dev Uses current tick from slot0, no time-weighting
     * @dev Price is normalized to 1e18 (WAD precision)
     * @return price The spot price scaled to 1e18
     */
    function getSpotPrice() external view returns (uint256 price);
}
