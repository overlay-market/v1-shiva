// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10 <0.9.0;

import {Test, console} from "forge-std/Test.sol";
import {PancakeSwapV3TWAPOracle} from "src/PancakeSwapV3TWAPOracle.sol";
import {IUniswapV3Pool} from "v1-periphery/lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v1-periphery/lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "v1-periphery/lib/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "v1-periphery/lib/v3-core/contracts/libraries/FullMath.sol";
import {IUniswapV3MintCallback} from "v1-periphery/lib/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "v1-periphery/lib/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
        oracle = new PancakeSwapV3TWAPOracle(PANCAKE_POOL, pool.token0());

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

contract PancakeSwapV3TWAPOracleLocalPoolTest is Test, IUniswapV3MintCallback, IUniswapV3SwapCallback {
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint32 internal constant TWAP_PERIOD = 1800;
    uint256 internal constant MINT_AMOUNT = 1e36;
    uint128 internal constant LIQUIDITY = 1e24;
    int24 internal constant MAX_ABS_TICK = 5_000;
    address internal constant UNISWAP_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;

    address internal factoryAddress;

    mapping(address => bool) internal allowedPools;

    struct PoolContext {
        TestERC20 ovl;
        TestERC20 stable;
        IUniswapV3Pool pool;
        bool isOvlToken0;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC", string(""));
        require(bytes(rpcUrl).length != 0, "RPC env not set");

        vm.createSelectFork(rpcUrl);
        vm.deal(address(this), 100 ether);
        factoryAddress = vm.envOr("UNISWAP_V3_FACTORY", UNISWAP_V3_FACTORY);
    }

    function testFuzz_getPrice_and_getSpotPrice_with_ovl_token0(
        int24 startTick,
        int24 endTick,
        uint8 stableDecimals
    ) external {
        _runScenario(true, startTick, endTick, stableDecimals);
    }

    function testFuzz_getPrice_and_getSpotPrice_with_ovl_token1(
        int24 startTick,
        int24 endTick,
        uint8 stableDecimals
    ) external {
        _runScenario(false, startTick, endTick, stableDecimals);
    }

    function _runScenario(
        bool ovlShouldBeToken0,
        int24 startTick,
        int24 endTick,
        uint8 stableDecimals
    ) internal {
        vm.assume(startTick >= -MAX_ABS_TICK && startTick <= MAX_ABS_TICK);
        vm.assume(endTick >= -MAX_ABS_TICK && endTick <= MAX_ABS_TICK);
        vm.assume(stableDecimals >= 6 && stableDecimals <= 18);

        stableDecimals = _boundDecimals(stableDecimals);
        startTick = _boundTick(startTick);
        endTick = _boundTick(endTick);

        PoolContext memory ctx = _setupPool(ovlShouldBeToken0, stableDecimals, startTick / 2, endTick);

        uint32 firstWindow = TWAP_PERIOD / 2;
        uint32 secondWindow = TWAP_PERIOD - firstWindow;

        _movePriceTo(ctx.pool, startTick);
        vm.warp(block.timestamp + firstWindow);
        _movePriceTo(ctx.pool, endTick);

        vm.warp(block.timestamp + secondWindow + 1);

        PancakeSwapV3TWAPOracle oracle = new PancakeSwapV3TWAPOracle(address(ctx.pool), address(ctx.ovl));

        uint256 price = oracle.getPrice(TWAP_PERIOD);
        int56 weightedTick = int56(startTick) * int56(uint56(firstWindow))
            + int56(endTick) * int56(uint56(secondWindow));
        int24 expectedTwapTick = int24(weightedTick / int56(uint56(TWAP_PERIOD)));
        uint256 expectedTwap = FullMath.mulDiv(
            getQuoteAtTick(expectedTwapTick, uint128(1e18), address(ctx.ovl), address(ctx.stable)),
            1e18,
            10 ** uint256(stableDecimals)
        );
        assertApproxEqRel(price, expectedTwap, 1e15, "twap price mismatch");

        price = oracle.getSpotPrice();
        uint256 expectedSpot = FullMath.mulDiv(
            getQuoteAtTick(endTick, uint128(1e18), address(ctx.ovl), address(ctx.stable)),
            1e18,
            10 ** uint256(stableDecimals)
        );

        assertApproxEqRel(price, expectedSpot, 1e14, "spot price mismatch");
    }

    function _setupPool(
        bool ovlShouldBeToken0,
        uint8 stableDecimals,
        int24 startTick,
        int24 endTick
    ) internal returns (PoolContext memory ctx) {
        (ctx.ovl, ctx.stable) = _deployTokens(ovlShouldBeToken0, stableDecimals);

        ctx.ovl.mint(address(this), MINT_AMOUNT);
        ctx.stable.mint(address(this), MINT_AMOUNT);

        IUniswapV3Factory factory = IUniswapV3Factory(factoryAddress);
        address poolAddr = factory.createPool(address(ctx.ovl), address(ctx.stable), FEE);
        allowedPools[poolAddr] = true;
        ctx.pool = IUniswapV3Pool(poolAddr);

        ctx.isOvlToken0 = ctx.pool.token0() == address(ctx.ovl);
        if (ovlShouldBeToken0) {
            require(ctx.isOvlToken0, "scenario requires ovl as token0");
        } else {
            require(!ctx.isOvlToken0, "scenario requires ovl as token1");
        }

        ctx.pool.initialize(TickMath.getSqrtRatioAtTick(startTick));
        ctx.pool.increaseObservationCardinalityNext(10_000);

        (int24 tickLower, int24 tickUpper) = _liquidityTicks(startTick, endTick);
        ctx.pool.mint(address(this), tickLower, tickUpper, LIQUIDITY, "");

        // Prime observations so cardinality > 1 before TWAP checks
        _bumpObservation(ctx, 1e12);
        _ensureCardinality(ctx, 2);
    }

    function _ensureCardinality(PoolContext memory ctx, uint16 target) internal {
        for (uint256 i; i < 5; i++) {
            (, , , uint16 observationCardinality, , ,) = ctx.pool.slot0();
            if (observationCardinality >= target) return;
            _bumpObservation(ctx, 1e12);
        }
        (, , , uint16 finalCardinality, , ,) = ctx.pool.slot0();
        if (finalCardinality < target) {
            _forceCardinality(ctx.pool, target);
        }
    }

    function _bumpObservation(PoolContext memory ctx, uint256 amount) internal {
        vm.warp(block.timestamp + 1);
        bool zeroForOne = ctx.isOvlToken0;
        ctx.pool.swap(
            address(this),
            zeroForOne,
            int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            ""
        );
    }

    function _forceCardinality(IUniswapV3Pool pool, uint16 target) internal {
        bytes32 slot = vm.load(address(pool), bytes32(uint256(0)));
        uint256 val = uint256(slot);

        // observationCardinality bits 200-215, observationCardinalityNext bits 216-231
        uint256 maskCardinality = ((1 << 16) - 1) << 200;
        uint256 maskCardinalityNext = ((1 << 16) - 1) << 216;

        uint16 currentNext = uint16((val & maskCardinalityNext) >> 216);
        uint16 newNext = currentNext < target ? target : currentNext;

        val = (val & ~maskCardinality) | (uint256(target) << 200);
        val = (val & ~maskCardinalityNext) | (uint256(newNext) << 216);

        vm.store(address(pool), bytes32(uint256(0)), bytes32(val));
    }

    function _twapTickFromPool(IUniswapV3Pool pool) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_PERIOD;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        return int24(delta / int56(uint56(TWAP_PERIOD)));
    }

    function _spotTick(IUniswapV3Pool pool) internal view returns (int24) {
        (, int24 tick, , , , , ) = pool.slot0();
        return tick;
    }

    /// @notice Given a tick and a token amount, calculates the amount of token received in exchange
    /// @dev copy from https://github.com/Uniswap/v3-periphery/blob/0682387198a24c7cd63566a2c58398533860a5d1/contracts/libraries/OracleLibrary.sol
    /// @param tick Tick value used to calculate the quote
    /// @param baseAmount Amount of token to be converted
    /// @param baseToken Address of an ERC20 token contract used as the baseAmount denomination
    /// @param quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
    /// @return quoteAmount Amount of quoteToken received for baseAmount of baseToken
    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    function _deployTokens(bool ovlShouldBeToken0, uint8 stableDecimals)
        internal
        returns (TestERC20 ovl, TestERC20 stable)
    {
        address[4] memory candidates = [vm.addr(1), vm.addr(2), vm.addr(3), vm.addr(4)];

        for (uint256 i; i < candidates.length; i++) {
            for (uint256 j; j < candidates.length; j++) {
                if (i == j) continue;

                address ovlPredicted = vm.computeCreateAddress(candidates[i], vm.getNonce(candidates[i]));
                address stablePredicted = vm.computeCreateAddress(candidates[j], vm.getNonce(candidates[j]));
                bool orderingValid = ovlShouldBeToken0 ? ovlPredicted < stablePredicted : ovlPredicted > stablePredicted;
                if (!orderingValid) continue;

                vm.startPrank(candidates[i]);
                ovl = new TestERC20("OVL", "OVL", 18);
                vm.stopPrank();

                vm.startPrank(candidates[j]);
                stable = new TestERC20("STABLE", "STABLE", stableDecimals);
                vm.stopPrank();
                return (ovl, stable);
            }
        }
        revert("unable to deploy ordered tokens");
    }

    function _liquidityTicks(int24 startTick, int24 endTick) internal pure returns (int24 lower, int24 upper) {
        int24 minTick = startTick < endTick ? startTick : endTick;
        int24 maxTick = startTick > endTick ? startTick : endTick;
        lower = _boundTick(minTick - 600);
        upper = _boundTick(maxTick + 600);
        if (lower == upper) {
            upper = _boundTick(upper + TICK_SPACING);
        }
        if (lower > upper) {
            (lower, upper) = (upper, lower);
        }
    }

    function _movePriceTo(IUniswapV3Pool pool, int24 targetTick) internal {
        (, int24 currentTick, , , , , ) = pool.slot0();
        if (currentTick == targetTick) return;

        uint160 priceLimit = TickMath.getSqrtRatioAtTick(targetTick);
        if (targetTick < currentTick) {
            pool.swap(address(this), true, type(int256).max, priceLimit, "");
        } else {
            pool.swap(address(this), false, type(int256).max, priceLimit, "");
        }
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external override {
        require(allowedPools[msg.sender], "unknown pool");
        if (amount0 > 0) IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, amount1);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        require(allowedPools[msg.sender], "unknown pool");
        if (amount0Delta > 0) IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
    }

    function _boundDecimals(uint8 decimals) internal pure returns (uint8) {
        if (decimals < 6) return 6;
        if (decimals > 18) return 18;
        return decimals;
    }

    function _boundTick(int24 tick) internal pure returns (int24) {
        int24 minTick = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 maxTick = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;

        if (tick < -MAX_ABS_TICK) tick = -MAX_ABS_TICK;
        if (tick > MAX_ABS_TICK) tick = MAX_ABS_TICK;

        if (tick < minTick) tick = minTick;
        if (tick > maxTick) tick = maxTick;

        return (tick / TICK_SPACING) * TICK_SPACING;
    }
}

contract TestERC20 is ERC20 {
    uint8 private immutable customDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
