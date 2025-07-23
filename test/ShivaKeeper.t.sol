// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {IShiva} from "src/IShiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {Utils} from "src/utils/Utils.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {IFluxAggregator} from "src/interfaces/aggregator/IFluxAggregator.sol";
import {IOverlayV1ChainlinkFeed} from "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";
import {Oracle} from "v1-core/contracts/libraries/Oracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/**
 * @title ShivaKeeperTest
 * @notice Test suite for the keeper functionalities in Shiva contract
 */
contract ShivaKeeperTest is ShivaTestBase {
    using FixedPoint for uint256;

    MockAggregator badAggregator;

    /**
     * @dev Sets up the initial state for the test contract.
     */
    function setUp() public override {
        super.setUp();
        vm.fee(10 gwei); // Set a base fee for the block to enable dynamic fee calculation
    }

    /**
     * @dev Test that limit order build with keeper fee calculates and pays the fee correctly
     */
    function test_limitOrderBuild_with_keeper_fee() public {
        uint256 collateral = 100e18;
        uint256 leverage = 2e18;

        // Get digest and signature for build on behalf of
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            collateral,
            leverage,
            type(uint256).max,
            FIXED_NONCE,
            uint48(block.timestamp + 3600),
            true,
            0,
            type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Get initial balances
        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        vm.prank(automator);
        limitOrderBuildOnBehalfOf(
            collateral,
            leverage,
            type(uint256).max,
            uint48(block.timestamp + 3600),
            true,
            signature,
            alice,
            type(uint256).max
        );

        // Check that keeper received the fee
        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee");
    }

    /**
     * @dev Test that take profit with keeper fee calculates and pays the fee correctly
     */
    function test_takeProfit_with_keeper_fee() public {
        // First build a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        vm.stopPrank();

        // Use a safe price limit
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        // Get digest and signature for unwind on behalf of
        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, uint48(block.timestamp + 3600), 0, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Record balances before
        uint256 keeperBalanceBefore = ovlToken.balanceOf(charlie);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        // Give keeper gas money
        vm.deal(charlie, 1 ether);

        vm.startPrank(charlie);
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, uint48(block.timestamp + 3600), signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // Check that keeper received the fee
        uint256 keeperBalanceAfter = ovlToken.balanceOf(charlie);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee");
    }

    /**
     * @dev Test that takeProfit reverts if the unwind amount is insufficient to pay the keeper fee.
     */
    function test_revert_takeProfit_insufficient_balance_for_fee() public {
        // 1. Arrange
        uint256 posId;
        uint256 keeperFee = 100e18; // 100 OVL

        // Scope to avoid stack too deep
        {
            // Set a high, predictable keeper fee for this test
            vm.startPrank(deployer);
            // Submit multiple times to ensure the micro-window average is updated
            vm.warp(block.timestamp + 60 * 60);
            keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
            vm.warp(block.timestamp + 60 * 60);
            keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
            vm.warp(block.timestamp + 60 * 60);
            keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
            vm.stopPrank();

            // Alice builds a position.
            uint256 collateral = 100e18;
            vm.startPrank(alice);
            posId = buildPosition(collateral, 2e18, 1, true); // Long position
            vm.stopPrank();

            // Set Alice's OVL balance to a low amount after she's paid for the position.
            deal(address(ovlToken), alice, 1e18);
            approveToken(alice); // Re-approve after dealing new balance

            // Manipulate price to make the position unprofitable but NOT liquidatable
            IFluxAggregator marketAggregator =
                IFluxAggregator(IOverlayV1ChainlinkFeed(ovlMarket.feed()).aggregator());
            address oracle = marketAggregator.getOracles()[0];
            int256 unprofitablePrice = marketAggregator.latestAnswer() * 70 / 100; // 30% drop

            vm.startPrank(oracle);
            marketAggregator.submit(marketAggregator.latestRound() + 1, unprofitablePrice);
            vm.warp(block.timestamp + 60 * 60);
            marketAggregator.submit(marketAggregator.latestRound() + 1, unprofitablePrice);
            vm.warp(block.timestamp + 60 * 60);
            marketAggregator.submit(marketAggregator.latestRound() + 1, unprofitablePrice);
            vm.stopPrank();
        }

        // 2. Act & Assert
        // Prepare the takeProfit call
        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, 0, FIXED_NONCE, uint48(block.timestamp + 3600), 0, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        vm.deal(automator, 1 ether); // Give keeper gas
        vm.startPrank(automator);

        // We expect the call to revert because Alice's balance (1 OVL) + the unprofitable
        // unwind proceeds will be less than the required keeperFee (100 OVL).
        uint256 aliceStartingBalance = 1e18;
        uint256 unwindProceeds = 38749294541325508928; // Value from test trace
        uint256 totalAvailableAmount = aliceStartingBalance + unwindProceeds;
        vm.expectRevert(
            abi.encodeWithSelector(
                IShiva.InsufficientBalanceForKeeperFee.selector, totalAvailableAmount, keeperFee
            )
        );

        takeProfitOnBehalfOf(
            posId, ONE, 0, uint48(block.timestamp + 3600), signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @dev Test that stop loss with keeper fee calculates and pays the fee correctly
     */
    function test_stopLoss_with_keeper_fee() public {
        // Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, BASIC_SLIPPAGE, true); // Long position
        vm.stopPrank();

        // To trigger stop loss for a long position, the market's bid price must be <= triggerPrice
        IOverlayV1ChainlinkFeed marketFeed = IOverlayV1ChainlinkFeed(ovlMarket.feed());
        Oracle.Data memory oracleData = marketFeed.latest();
        uint256 currentBidPrice = ovlMarket.bid(oracleData, 0);

        // Set the trigger price slightly above the current bid to have a target
        uint256 triggerPrice = currentBidPrice * 101 / 100; // 1% above current bid

        // Now, drop the oracle price significantly to ensure the new bid price is below the trigger
        IFluxAggregator marketAggregator = IFluxAggregator(marketFeed.aggregator());
        address oracle = marketAggregator.getOracles()[0];
        int256 newOraclePrice = int256(triggerPrice * 95 / 100); // Drop oracle price 5% below trigger
        // Scale down to 8 decimals for the mock aggregator
        newOraclePrice = newOraclePrice / 1e10;

        vm.startPrank(oracle);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.warp(block.timestamp + 60 * 60);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.warp(block.timestamp + 60 * 60);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.stopPrank();

        uint256 priceLimit = 0;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, 0, true, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);
        vm.deal(automator, 1 ether); // give gas money

        // Automator executes the transaction for Alice
        vm.startPrank(automator);
        stopLossOnBehalfOf(
            posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true, type(uint256).max
        );
        vm.stopPrank();

        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee");
    }

    /**
     * @dev Test that stop loss does not pay a fee when payKeeperFee is false
     */
    function test_stopLoss_no_keeper_fee_when_false() public {
        // Set a high keeper fee
        vm.startPrank(deployer);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, 10e8); // 10 OVL fee
        vm.stopPrank();

        // Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, BASIC_SLIPPAGE, true); // Long position
        vm.stopPrank();

        // Set up trigger condition deterministically
        IOverlayV1ChainlinkFeed marketFeed = IOverlayV1ChainlinkFeed(ovlMarket.feed());
        Oracle.Data memory oracleData = marketFeed.latest();
        uint256 currentBidPrice = ovlMarket.bid(oracleData, 0);
        uint256 triggerPrice = currentBidPrice * 101 / 100;

        IFluxAggregator marketAggregator = IFluxAggregator(marketFeed.aggregator());
        address oracle = marketAggregator.getOracles()[0];
        int256 newOraclePrice = int256(triggerPrice * 95 / 100);
        // Scale down to 8 decimals for the mock aggregator
        newOraclePrice = newOraclePrice / 1e10;

        vm.startPrank(oracle);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.warp(block.timestamp + 60 * 60);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.warp(block.timestamp + 60 * 60);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.stopPrank();

        uint256 priceLimit = 0;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, 0, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(bob);
        vm.deal(bob, 1 ether);

        // Bob executes the transaction for Alice with payKeeperFee = false
        vm.startPrank(bob);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();

        uint256 keeperBalanceAfter = ovlToken.balanceOf(bob);
        assertEq(keeperBalanceAfter, keeperBalanceBefore, "Keeper should not receive a fee");
    }

    /**
     * @dev Test that limitOrderBuild reverts if the user has insufficient balance for the keeper fee.
     */
    function test_revert_limitOrderBuild_insufficient_balance_for_fee() public {
        // 1. Arrange
        // Set a higher, predictable keeper fee for this test
        uint256 keeperFee = 10e18; // 10 OVL
        vm.startPrank(deployer);
        // Submit multiple times to ensure the micro-window average is updated
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;
        uint256 notional = collateral.mulUp(leverage);
        uint256 tradingFeeRate = ovlMarket.params(uint256(Risk.Parameters.TradingFeeRate));
        uint256 tradingFee = notional.mulUp(tradingFeeRate);

        // Set Alice's balance: enough for collateral and trading fee, but not for the keeper fee.
        uint256 aliceBalance = collateral + tradingFee;
        deal(address(ovlToken), alice, aliceBalance);
        approveToken(alice); // Re-approve after dealing new balance

        // Get digest and signature for the transaction
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            collateral,
            leverage,
            type(uint256).max, // priceLimit
            FIXED_NONCE,
            uint48(block.timestamp + 3600), // deadline
            true, // isLong
            0, // brokerId
            type(uint256).max // maxKeeperFee
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 2. Act & Assert
        vm.deal(automator, 1 ether); // Give keeper gas
        vm.prank(automator);

        // We expect the call to revert because Alice's balance after paying for the position
        // (which is now 0) is less than the required keeperFee.
        vm.expectRevert(
            abi.encodeWithSelector(IShiva.InsufficientBalanceForKeeperFee.selector, 0, keeperFee)
        );

        limitOrderBuildOnBehalfOf(
            collateral,
            leverage,
            type(uint256).max, // priceLimit
            uint48(block.timestamp + 3600), // deadline
            true, // isLong
            signature,
            alice,
            type(uint256).max // maxKeeperFee
        );
    }

    /**
     * @dev Test that take profit with a partial unwind still pays the keeper fee correctly.
     */
    function test_takeProfit_partial_unwind_with_keeper_fee() public {
        // Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        vm.stopPrank();

        // Unwind 50% of the position
        uint256 fractionToUnwind = ONE / 2;

        // Use a safe price limit
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), fractionToUnwind, BASIC_SLIPPAGE);

        // Get digest and signature for unwind on behalf of
        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId,
            fractionToUnwind,
            priceLimit,
            FIXED_NONCE,
            uint48(block.timestamp + 3600),
            0,
            type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Record balances before
        uint256 keeperBalanceBefore = ovlToken.balanceOf(charlie);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        // Give keeper gas money
        vm.deal(charlie, 1 ether);

        vm.startPrank(charlie);
        takeProfitOnBehalfOf(
            posId,
            fractionToUnwind,
            priceLimit,
            uint48(block.timestamp + 3600),
            signature,
            alice,
            type(uint256).max
        );
        vm.stopPrank();

        // Check that keeper received the fee
        uint256 keeperBalanceAfter = ovlToken.balanceOf(charlie);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee for partial unwind");
    }

    /**
     * @dev Test that keeper fee is still paid when keeper fee is set to zero.
     */
    function test_keeper_payment_with_zero_fee() public {
        // 1. Arrange
        // Set a zero keeper fee
        uint256 keeperFee = 0;
        vm.startPrank(deployer);
        // Submit multiple times to ensure the micro-window average is updated
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee));
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;

        // Get digest and signature for build on behalf of
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            collateral,
            leverage,
            type(uint256).max, // priceLimit
            FIXED_NONCE,
            uint48(block.timestamp + 3600), // deadline
            true, // isLong
            0, // brokerId
            0 // maxKeeperFee can be zero
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 2. Act
        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);

        vm.deal(automator, 1 ether);
        vm.prank(automator);
        uint256 posId = limitOrderBuildOnBehalfOf(
            collateral,
            leverage,
            type(uint256).max, // priceLimit
            uint48(block.timestamp + 3600), // deadline
            true, // isLong
            signature,
            alice,
            0 // maxKeeperFee
        );

        // 3. Assert
        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertEq(
            keeperBalanceAfter - keeperBalanceBefore,
            keeperFee,
            "Keeper should receive zero fee"
        );
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    /**
     * @dev Test that stopLoss reverts if the unwind amount is insufficient to pay the keeper fee.
     */
    function test_revert_stopLoss_insufficient_balance_for_fee() public {
        // 1. Arrange
        uint256 keeperFee = 100e18; // 100 OVL
        vm.startPrank(deployer);
        // Submit multiple times to ensure the micro-window average is updated
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.stopPrank();

        uint256 posId;
        uint256 triggerPrice;
        { // Scope to avoid stack too deep
            // Alice builds a long position
            vm.startPrank(alice);
            posId = buildPosition(100e18, 2e18, BASIC_SLIPPAGE, true);
            vm.stopPrank();

            // Set Alice's balance to a low amount after building
            deal(address(ovlToken), alice, 1e18); // 1 OVL
            approveToken(alice);

            // Trigger stop loss condition by dropping the price
            IOverlayV1ChainlinkFeed marketFeed = IOverlayV1ChainlinkFeed(ovlMarket.feed());
            Oracle.Data memory oracleData = marketFeed.latest();
            triggerPrice = ovlMarket.bid(oracleData, 0) * 99 / 100; // Trigger just below current

            IFluxAggregator marketAggregator = IFluxAggregator(marketFeed.aggregator());
            address oracle = marketAggregator.getOracles()[0];
            // Drop price by 30% to make it unprofitable and trigger the stop loss
            int256 unprofitablePrice = marketAggregator.latestAnswer() * 70 / 100;

            vm.startPrank(oracle);
            marketAggregator.submit(marketAggregator.latestRound() + 1, unprofitablePrice);
            vm.warp(block.timestamp + 60 * 60);
            marketAggregator.submit(marketAggregator.latestRound() + 1, unprofitablePrice);
            vm.warp(block.timestamp + 60 * 60);
            marketAggregator.submit(marketAggregator.latestRound() + 1, unprofitablePrice);
            vm.stopPrank();
        }

        // 2. Act & Assert
        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, 0, uint48(block.timestamp + 3600), FIXED_NONCE, 0, true, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        vm.deal(automator, 1 ether);
        vm.startPrank(automator);

        // Expect revert because Alice's balance (1 OVL) + unwind proceeds < keeperFee (100 OVL)
        vm.expectRevert(
            abi.encodeWithSelector(
                IShiva.InsufficientBalanceForKeeperFee.selector,
                1e18 + 38749294541325508928, // aliceStartingBalance + unwindProceeds
                keeperFee
            )
        );

        stopLossOnBehalfOf(
            posId, ONE, triggerPrice, 0, uint48(block.timestamp + 3600), signature, alice, true, type(uint256).max
        );

        vm.stopPrank();
    }

    /**
     * @dev Test that a keeper transaction succeeds when maxKeeperFee is exactly equal to the calculated fee.
     */
    function test_succeeds_when_maxKeeperFee_equals_calculated_fee() public {
        // 1. Arrange
        // Set a predictable keeper fee
        uint256 keeperFee = 10e18; // 10 OVL
        vm.startPrank(deployer);
        // Submit multiple times to ensure the micro-window average is updated
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;

        // Get digest and signature for build on behalf of
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            collateral,
            leverage,
            type(uint256).max, // priceLimit
            FIXED_NONCE,
            uint48(block.timestamp + 3600), // deadline
            true, // isLong
            0, // brokerId
            keeperFee // Set maxKeeperFee exactly equal to the calculated fee
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 2. Act
        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);

        vm.deal(automator, 1 ether);
        vm.prank(automator);
        uint256 posId = limitOrderBuildOnBehalfOf(
            collateral,
            leverage,
            type(uint256).max, // priceLimit
            uint48(block.timestamp + 3600), // deadline
            true, // isLong
            signature,
            alice,
            keeperFee // Use the exact fee as the max
        );

        // 3. Assert
        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertEq(
            keeperBalanceAfter - keeperBalanceBefore,
            keeperFee,
            "Keeper should receive the exact fee"
        );
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    /**
     * @dev Test that takeProfit succeeds even on an unprofitable unwind, as long as the fee is covered.
     */
    function test_takeProfit_unprofitable_unwind_with_fee() public {
        // Alice builds a position
        uint256 collateral = 100e18;
        vm.startPrank(alice);
        uint256 posId = buildPosition(collateral, 2e18, 1, true); // Long position
        vm.stopPrank();

        // Manipulate price to make the position unprofitable
        IFluxAggregator marketAggregator = IFluxAggregator(IOverlayV1ChainlinkFeed(ovlMarket.feed()).aggregator());
        address oracle = marketAggregator.getOracles()[0];
        int256 currentPrice = marketAggregator.latestAnswer();
        int256 unprofitablePrice = currentPrice * 90 / 100; // 10% drop

        vm.startPrank(oracle);
        marketAggregator.submit(marketAggregator.latestRound() + 1, unprofitablePrice);
        vm.stopPrank();

        // A price limit of 0 means we accept any price
        uint256 priceLimit = 0;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getTakeProfitOnBehalfOfDigest(posId, ONE, priceLimit, FIXED_NONCE, deadline, 0, type(uint256).max);
        bytes memory signature = getSignature(digest, alicePk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(charlie);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        vm.deal(charlie, 1 ether);

        vm.startPrank(charlie);
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        uint256 keeperBalanceAfter = ovlToken.balanceOf(charlie);
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);

        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should still receive a fee");
        assertLt(aliceBalanceAfter, aliceBalanceBefore + collateral, "Alice's balance should reflect a loss");
    }

    /**
     * @dev Test that any keeper transaction reverts if the nativeOvlFeed is failing.
     */
    function test_revert_on_nativeOvlFeed_failure() public {
        // Deploy a new bad aggregator that has no data
        badAggregator = new MockAggregator();
        // Deploy a new feed with this bad aggregator
        IOverlayV1ChainlinkFeed badFeed = IOverlayV1ChainlinkFeed(
            feedFactory.deployFeed(address(badAggregator), 172800)
        );

        // Set the bad feed in Shiva
        vm.startPrank(deployer);
        shiva.setKeeperFeeFeed(badFeed);
        vm.stopPrank();

        // Prepare a standard limitOrderBuild call
        uint256 collateral = 100e18;
        uint256 leverage = 2e18;
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            collateral,
            leverage,
            type(uint256).max,
            FIXED_NONCE,
            uint48(block.timestamp + 3600),
            true,
            0,
            type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        vm.deal(automator, 1 ether);
        vm.prank(automator);

        // The call should revert because nativeOvlFeed.latest() will fail internally
        vm.expectRevert("No data present");
        limitOrderBuildOnBehalfOf(
            collateral,
            leverage,
            type(uint256).max,
            uint48(block.timestamp + 3600),
            true,
            signature,
            alice,
            type(uint256).max
        );
    }

    /**
     * @dev Test that keeper payment reverts if the owner has not approved Shiva to spend OVL for the fee.
     */
    function test_revert_when_owner_has_not_approved_shiva_for_keeper_fee() public {
        // 1. Arrange
        // Set a predictable keeper fee
        uint256 keeperFee = 10e18;
        vm.startPrank(deployer);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(keeperFee / 1e10));
        vm.stopPrank();

        // Alice builds a position (which requires approval)
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        // After building, Alice revokes Shiva's approval
        ovlToken.approve(address(shiva), 0);
        vm.stopPrank();

        // Prepare the takeProfit call
        uint256 priceLimit = 0; // Accept any price
        uint48 deadline = uint48(block.timestamp + 3600);
        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, 0, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 2. Act & Assert
        vm.deal(automator, 1 ether);
        vm.startPrank(automator);

        // Expect revert from the OVL token contract due to insufficient allowance
        vm.expectRevert("ERC20: insufficient allowance");

        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }
} 