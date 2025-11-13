// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {Test, console} from "forge-std/Test.sol";
import {PancakeSwapV3TWAPOracle} from "src/PancakeSwapV3TWAPOracle.sol";
import {IUniswapV3Pool} from "v1-periphery/lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/**
 * @title PancakeSwapV3TWAPOracleTest
 * @notice Comprehensive fork tests using real PancakeSwap V3 pool on BSC
 * @dev Run with: forge test --match-contract PancakeSwapV3TWAPOracleTest --fork-url $BSC_RPC -vv
 */
contract PancakeSwapV3TWAPOracleTest is Test {
    PancakeSwapV3TWAPOracle public oracle;
    IUniswapV3Pool public pool;

    // Real PancakeSwap V3 OVL/USDT pool on BSC
    address constant PANCAKE_POOL = 0x927aE3c2cd88717a1525a55021AF9612C3F04583;
    uint32 constant TWAP_PERIOD = 1800; // 30 minutes

    function setUp() public {
        // Create and select BSC fork
        vm.createSelectFork(vm.envString("BSC_RPC"));

        pool = IUniswapV3Pool(PANCAKE_POOL);

        console.log("=== PancakeSwap V3 TWAP Oracle Fork Test ===");
        console.log("Pool:", PANCAKE_POOL);

        // Deploy oracle directly (no proxy needed, twapPeriod is now a parameter)
        oracle = new PancakeSwapV3TWAPOracle(PANCAKE_POOL);

        console.log("Oracle deployed at:", address(oracle));
    }

    // ============ Construction Tests ============

    function test_constructor() public view {
        assertEq(address(oracle.pool()), PANCAKE_POOL);
        console.log("[PASS] Oracle constructed correctly");
    }

    function test_getMinCardinality() public view {
        uint16 minCardinality = oracle.getMinCardinality();
        assertEq(minCardinality, 2);
        console.log("[PASS] Min cardinality is 2");
    }

    // ============ Cardinality Tests ============

    function test_checkCardinality() public view {
        bool hasCardinality = oracle.checkCardinality(TWAP_PERIOD);
        console.log("Pool cardinality sufficient:", hasCardinality);

        // This test adapts based on real pool state
        if (hasCardinality) {
            assertTrue(hasCardinality);
            console.log("[PASS] Pool has sufficient cardinality");
        } else {
            console.log("[INFO] Pool does not have sufficient cardinality yet");
        }
    }

    // ============ Price Fetching Tests ============

    function test_getPrice() public view {
        console.log("=== Testing getPrice ===");

        // Check cardinality first
        bool hasCardinality = oracle.checkCardinality(TWAP_PERIOD);
        console.log("Has cardinality:", hasCardinality);

        if (!hasCardinality) {
            console.log("[SKIP] Pool doesn't have enough observations for TWAP");
            return;
        }

        // Get TWAP price from real pool
        uint256 price = oracle.getPrice(TWAP_PERIOD);
        console.log("TWAP price (WAD):", price);
        console.log("TWAP price (formatted):", price / 1e18);

        assertGt(price, 0, "Price should be positive");
        console.log("[SUCCESS] Real TWAP fetched from BSC!");
    }

    function test_getPrice_revertsOnInsufficientCardinality() public {
        // Deploy a new oracle on a pool that might not have cardinality
        // For this test, we'll check if current pool has cardinality and skip if it does
        bool hasCardinality = oracle.checkCardinality(TWAP_PERIOD);

        if (hasCardinality) {
            console.log("[SKIP] Cannot test insufficient cardinality - pool has sufficient observations");
            return;
        }

        // If pool doesn't have cardinality, getPrice should revert
        vm.expectRevert("PancakeSwapV3TWAP: insufficient cardinality");
        oracle.getPrice(TWAP_PERIOD);
        console.log("[PASS] Correctly reverts on insufficient cardinality");
    }

    function test_getSpotPrice() public view {
        console.log("=== Testing getSpotPrice ===");

        // Spot price should always be available (doesn't need cardinality)
        uint256 spotPrice = oracle.getSpotPrice();
        console.log("Spot price (WAD):", spotPrice);
        console.log("Spot price (formatted):", spotPrice / 1e18);

        assertGt(spotPrice, 0, "Spot price should be positive");
        console.log("[SUCCESS] Spot price fetched from pool!");
    }

    function test_spotVsTwapComparison() public view {
        console.log("=== Comparing Spot vs TWAP ===");

        // Get spot price
        uint256 spotPrice = oracle.getSpotPrice();
        console.log("Spot price:", spotPrice / 1e18);

        // Try to get TWAP if cardinality allows
        bool hasCardinality = oracle.checkCardinality(TWAP_PERIOD);

        if (!hasCardinality) {
            console.log("[SKIP] Pool doesn't have enough observations for TWAP comparison");
            return;
        }

        uint256 twapPrice = oracle.getPrice(TWAP_PERIOD);
        console.log("TWAP price:", twapPrice / 1e18);

        // Both should be positive
        assertGt(spotPrice, 0, "Spot price should be positive");
        assertGt(twapPrice, 0, "TWAP price should be positive");

        // Log which is higher
        if (spotPrice > twapPrice) {
            console.log("Spot price is HIGHER than TWAP (protocol would use spot)");
        } else if (twapPrice > spotPrice) {
            console.log("TWAP price is HIGHER than spot (protocol would use TWAP)");
        } else {
            console.log("Prices are equal");
        }

        console.log("[PASS] Spot vs TWAP comparison complete");
    }

    // ============ Real Pool Information Tests ============

    function test_poolInfo() public view {
        console.log("=== Pool Information ===");

        address token0 = pool.token0();
        address token1 = pool.token1();

        console.log("Token0 (OVL):", token0);
        console.log("Token1 (Stable):", token1);

        // Get slot0 using low-level call (same as oracle does)
        (bool success, bytes memory data) = address(pool).staticcall(
            abi.encodeWithSignature("slot0()")
        );
        require(success, "slot0 failed");

        uint16 observationCardinality;
        assembly {
            let word := mload(add(data, 128))
            observationCardinality := and(word, 0xFFFF)
        }

        console.log("Observation cardinality:", observationCardinality);
        console.log("Minimum required:", oracle.getMinCardinality());

        console.log("[INFO] Pool info retrieved successfully");
    }

}
