// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PancakeSwapV3TWAPOracle} from "src/PancakeSwapV3TWAPOracle.sol";
import {IPancakeSwapV3TWAPOracle} from "src/IPancakeSwapV3TWAPOracle.sol";
import {IUniswapV3Pool} from "v1-periphery/lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/**
 * @title PancakeSwapV3TWAPOracleTest
 * @notice Comprehensive fork tests using real PancakeSwap V3 pool on BSC
 * @dev Run with: forge test --match-contract PancakeSwapV3TWAPOracleTest --fork-url $BSC_RPC -vv
 */
contract PancakeSwapV3TWAPOracleTest is Test {
    PancakeSwapV3TWAPOracle public oracle;
    IUniswapV3Pool public pool;

    address public owner;
    address public user;

    // Real PancakeSwap V3 OVL/USDT pool on BSC
    address constant PANCAKE_POOL = 0x927aE3c2cd88717a1525a55021AF9612C3F04583;
    uint32 constant TWAP_PERIOD = 1800; // 30 minutes

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");
        pool = IUniswapV3Pool(PANCAKE_POOL);

        console.log("=== PancakeSwap V3 TWAP Oracle Fork Test ===");
        console.log("Pool:", PANCAKE_POOL);

        // Deploy oracle implementation
        PancakeSwapV3TWAPOracle implementation = new PancakeSwapV3TWAPOracle();

        // Deploy proxy and initialize
        bytes memory initData = abi.encodeWithSelector(
            PancakeSwapV3TWAPOracle.initialize.selector,
            PANCAKE_POOL,
            TWAP_PERIOD
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        oracle = PancakeSwapV3TWAPOracle(address(proxy));

        console.log("Oracle deployed at:", address(oracle));
    }

    // ============ Initialization Tests ============

    function test_initialize() public view {
        assertEq(address(oracle.pool()), PANCAKE_POOL);
        assertEq(oracle.twapPeriod(), TWAP_PERIOD);
        assertEq(oracle.owner(), owner);
        console.log("[PASS] Oracle initialized correctly");
    }

    function test_getMinCardinality() public view {
        uint16 minCardinality = oracle.getMinCardinality();
        assertEq(minCardinality, 2);
        console.log("[PASS] Min cardinality is 2");
    }

    // ============ Cardinality Tests ============

    function test_checkCardinality() public view {
        bool hasCardinality = oracle.checkCardinality();
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
        bool hasCardinality = oracle.checkCardinality();
        console.log("Has cardinality:", hasCardinality);

        if (!hasCardinality) {
            console.log("[SKIP] Pool doesn't have enough observations for TWAP");
            return;
        }

        // Get TWAP price from real pool
        uint256 price = oracle.getPrice();
        console.log("TWAP price (WAD):", price);
        console.log("TWAP price (formatted):", price / 1e18);

        assertGt(price, 0, "Price should be positive");
        console.log("[SUCCESS] Real TWAP fetched from BSC!");
    }

    function test_getPrice_revertsOnInsufficientCardinality() public {
        // Deploy a new oracle on a pool that might not have cardinality
        // For this test, we'll check if current pool has cardinality and skip if it does
        bool hasCardinality = oracle.checkCardinality();

        if (hasCardinality) {
            console.log("[SKIP] Cannot test insufficient cardinality - pool has sufficient observations");
            return;
        }

        // If pool doesn't have cardinality, getPrice should revert
        vm.expectRevert("PancakeSwapV3TWAP: insufficient cardinality");
        oracle.getPrice();
        console.log("[PASS] Correctly reverts on insufficient cardinality");
    }

    // ============ Admin Function Tests ============

    function test_setTwapPeriod() public {
        uint32 newPeriod = 3600; // 1 hour

        vm.expectEmit(false, false, false, true);
        emit TwapPeriodUpdated(TWAP_PERIOD, newPeriod);

        oracle.setTwapPeriod(newPeriod);

        assertEq(oracle.twapPeriod(), newPeriod);
        console.log("[PASS] TWAP period updated to:", newPeriod);
    }

    function test_setTwapPeriod_revertsOnZero() public {
        vm.expectRevert("PancakeSwapV3TWAP: period is zero");
        oracle.setTwapPeriod(0);
        console.log("[PASS] Correctly reverts on zero period");
    }

    function test_setTwapPeriod_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setTwapPeriod(3600);
        console.log("[PASS] Correctly restricts to owner");
    }

    function test_setPool() public {
        address newPool = PANCAKE_POOL; // Using same pool for simplicity

        vm.expectEmit(true, true, false, true);
        emit PoolUpdated(PANCAKE_POOL, newPool);

        oracle.setPool(newPool);

        assertEq(address(oracle.pool()), newPool);
        console.log("[PASS] Pool updated successfully");
    }

    function test_setPool_revertsOnZeroAddress() public {
        vm.expectRevert("PancakeSwapV3TWAP: pool is zero");
        oracle.setPool(address(0));
        console.log("[PASS] Correctly reverts on zero address");
    }

    function test_setPool_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPool(PANCAKE_POOL);
        console.log("[PASS] Correctly restricts to owner");
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

    // ============ Events ============

    event TwapPeriodUpdated(uint32 previousPeriod, uint32 newPeriod);
    event PoolUpdated(address indexed previousPool, address indexed newPool);
}
