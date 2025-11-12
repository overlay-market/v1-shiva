// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IPancakeSwapV3TWAPOracle} from "./IPancakeSwapV3TWAPOracle.sol";
import {IUniswapV3Pool} from
    "v1-periphery/lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "v1-periphery/lib/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "v1-periphery/lib/v3-core/contracts/libraries/FullMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Minimal interface for PancakeSwap V3 Pool slot0
 * @dev PancakeSwap modified slot0 to use uint32 for feeProtocol instead of uint8
 * @dev See: https://developer.pancakeswap.finance/contracts/v3/pancakev3pool
 */
interface IPancakeV3PoolSlot0 {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,  // uint32 in PancakeSwap vs uint8 in Uniswap
            bool unlocked
        );
}

/**
 * @title PancakeSwapV3TWAPOracle
 * @notice Provides time-weighted average price from PancakeSwap V3 pools
 * @dev Fetches TWAP from PancakeSwap V3 pool observations
 * @dev Returns the price of token0 denominated in token1 (how many token1 per 1 token0)
 * @dev For OVL/USDT pool: returns USDT price per 1 OVL (e.g., 0.06 means 1 OVL = 0.06 USDT)
 * @dev Price is normalized to 1e18 (WAD precision)
 */
contract PancakeSwapV3TWAPOracle is IPancakeSwapV3TWAPOracle, Ownable {
    /// @notice Precision for price calculations (WAD)
    uint256 private constant WAD = 1e18;

    /// @notice Fixed point 96 precision used by Uniswap V3
    uint256 private constant Q96 = 2 ** 96;

    /// @notice Maximum TWAP period (7 days)
    uint32 private constant MAX_TWAP_PERIOD = 7 days;

    /// @notice PancakeSwap V3 pool contract
    IUniswapV3Pool public pool;

    /// @notice Scaling factor for token0 (OVL)
    uint256 private token0Decimals;

    /// @notice Scaling factor for token1 (Stable)
    uint256 private token1Decimals;

    /**
     * @notice Creates a new TWAP oracle
     * @param _pool Address of the PancakeSwap V3 pool
     */
    constructor(address _pool) {
        require(_pool != address(0), "PancakeSwapV3TWAP: pool is zero");

        pool = IUniswapV3Pool(_pool);

        // Get token decimals for proper price scaling
        address token0 = pool.token0();
        address token1 = pool.token1();
        token0Decimals = 10 ** uint256(IERC20Metadata(token0).decimals());
        token1Decimals = 10 ** uint256(IERC20Metadata(token1).decimals());

        emit PoolUpdated(address(0), _pool);
    }

    /// @inheritdoc IPancakeSwapV3TWAPOracle
    function getPrice(uint32 twapPeriod) external view override returns (uint256 price) {
        require(twapPeriod > 0, "PancakeSwapV3TWAP: period is zero");
        require(twapPeriod <= MAX_TWAP_PERIOD, "PancakeSwapV3TWAP: period too long");
        require(checkCardinality(twapPeriod), "PancakeSwapV3TWAP: insufficient cardinality");

        // Get TWAP tick
        int24 twapTick = _getTwapTick(twapPeriod);

        // Convert tick to price
        price = _getQuoteAtTick(twapTick);
    }

    /// @inheritdoc IPancakeSwapV3TWAPOracle
    function checkCardinality(uint32 twapPeriod) public view override returns (bool) {
        // Use PancakeSwap-specific interface for slot0 to handle uint32 feeProtocol
        (
            , // sqrtPriceX96
            , // tick
            , // observationIndex
            uint16 observationCardinality,
            , // observationCardinalityNext
            , // feeProtocol (uint32 in PancakeSwap, uint8 in Uniswap)
            // unlocked
        ) = IPancakeV3PoolSlot0(address(pool)).slot0();

        // First check: We need at least minimum observations
        if (observationCardinality < getMinCardinality()) {
            return false;
        }

        // Second check: Verify we can actually query the TWAP period
        // Try to observe the twapPeriod to ensure observations go back far enough
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos) returns (int56[] memory, uint160[] memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IPancakeSwapV3TWAPOracle
    function getMinCardinality() public pure override returns (uint16) {
        // Minimum 2 observations needed for TWAP
        // In practice, recommend having more for better granularity
        return 2;
    }

    /// @inheritdoc IPancakeSwapV3TWAPOracle
    function getSpotPrice() external view override returns (uint256 price) {
        // Get current tick from slot0
        (, int24 currentTick, , , , , ) = IPancakeV3PoolSlot0(address(pool)).slot0();

        // Convert current tick to price
        price = _getQuoteAtTick(currentTick);
    }

    /**
     * @notice Updates the pool address
     * @param newPool New pool address
     */
    function setPool(address newPool) external onlyOwner {
        require(newPool != address(0), "PancakeSwapV3TWAP: pool is zero");
        address previousPool = address(pool);
        pool = IUniswapV3Pool(newPool);

        // Update token decimals
        address token0 = pool.token0();
        address token1 = pool.token1();
        token0Decimals = 10 ** uint256(IERC20Metadata(token0).decimals());
        token1Decimals = 10 ** uint256(IERC20Metadata(token1).decimals());

        emit PoolUpdated(previousPool, newPool);
    }

    /**
     * @dev Calculates the time-weighted average tick from the pool
     * @param twapPeriod The TWAP period in seconds
     * @return twapTick The arithmetic mean tick over the TWAP period
     */
    function _getTwapTick(uint32 twapPeriod) internal view returns (int24 twapTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod; // e.g., 1800 seconds ago
        secondsAgos[1] = 0; // now

        // Call observe to get tick cumulatives
        // This will revert if observations don't go back far enough
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);

        // Calculate arithmetic mean tick
        int56 tickCumulativeDelta = tickCumulatives[1] - tickCumulatives[0];

        // Validate that we have meaningful price data
        // If delta is 0, it means no trades occurred in the period
        // This is acceptable (price remained constant) but we should validate the tick is within bounds

        int56 timeWeightedAverageTick = tickCumulativeDelta / int56(uint56(twapPeriod));

        // Ensure the calculated tick is within valid Uniswap V3 bounds
        require(
            timeWeightedAverageTick >= TickMath.MIN_TICK && timeWeightedAverageTick <= TickMath.MAX_TICK,
            "PancakeSwapV3TWAP: tick out of bounds"
        );

        // Convert to int24 (safe after bounds check)
        twapTick = int24(timeWeightedAverageTick);
    }

    /**
     * @dev Converts a tick to a price with proper decimal handling
     * @param tick The tick to convert
     * @return price The price in WAD (1e18) format representing OVL price in stable terms
     */
    function _getQuoteAtTick(int24 tick) internal view returns (uint256 price) {
        // Get sqrt price from tick
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);

        // sqrtPriceX96 = sqrt(token1/token0) * 2^96 = sqrt(Stable/OVL) * 2^96
        // We want OVL price in Stable terms = OVL/Stable = token0/token1

        // Calculate how much token1 (Stable) we get for token1Decimals amount
        // and how much token0 (OVL) that corresponds to

        // For baseAmount of token0 (OVL), we get quoteAmount of token1 (Stable)
        // price of token0 in terms of token1 = quoteAmount / baseAmount

        // Using 1 unit of token0 as base (token0Decimals):
        uint256 baseAmount = token0Decimals;

        // quoteAmount = baseAmount * (token1/token0)
        // token1/token0 = (sqrtPriceX96 / 2^96)^2

        // Calculate: quoteAmount = baseAmount * sqrtPriceX96^2 / 2^192
        // 2^192 = Q96 * Q96, so we need to divide by Q96 twice
        uint256 quoteAmount;
        if (sqrtPriceX96 <= type(uint128).max) {
            // Safe to square directly since sqrtPriceX96 fits in uint128
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            // Divide by 2^192 in a single operation to preserve precision
            quoteAmount = FullMath.mulDiv(baseAmount, ratioX192, Q96 * Q96);
        } else {
            // For large sqrtPriceX96, use intermediate scaling to prevent overflow
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            quoteAmount = FullMath.mulDiv(baseAmount, ratioX128, 1 << 128);
        }

        // quoteAmount represents how much Stable (token1) we get for baseAmount of OVL (token0)
        // So quoteAmount/baseAmount = Stable/OVL in raw token units
        // We want the price of OVL in Stable terms (how many Stable per OVL)

        // Price = (quoteAmount/token1Decimals) / (baseAmount/token0Decimals) * WAD
        // = quoteAmount * token0Decimals * WAD / (baseAmount * token1Decimals)

        require(quoteAmount > 0, "PancakeSwapV3TWAP: quote is zero");

        // Calculate: (quoteAmount * token0Decimals * WAD) / (baseAmount * token1Decimals)
        // Using two-step calculation to handle potential overflow
        uint256 numerator = FullMath.mulDiv(quoteAmount, token0Decimals, token1Decimals);
        price = FullMath.mulDiv(numerator, WAD, baseAmount);

        require(price > 0, "PancakeSwapV3TWAP: price is zero");
    }
}
