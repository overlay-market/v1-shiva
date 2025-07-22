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
     * @dev Group of tests for the keeper incentive
     */

    /**
     * @dev Test that the governor can set the keeper incentive
     */
    function test_setKeeperIncentive() public {
        uint256 newIncentive = 0.5e16; // 0.5%

        vm.startPrank(deployer);
        shiva.setKeeperIncentive(newIncentive);
        vm.stopPrank();

        assertEq(shiva.keeperIncentive(), newIncentive, "Keeper incentive should be updated");
    }

    /**
     * @dev Test that a non-governor cannot set the keeper incentive
     */
    function test_revert_setKeeperIncentive_not_governor() public {
        uint256 newIncentive = 0.5e16; // 0.5%

        vm.startPrank(alice);
        vm.expectRevert("Shiva: !governor");
        shiva.setKeeperIncentive(newIncentive);
        vm.stopPrank();
    }

    /**
     * @dev Test that limit order build with keeper fee calculates and pays the fee correctly
     */
    function test_limitOrderBuild_with_keeper_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(0.1e16); // 0.1%
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;

        // Get digest and signature for build on behalf of
        bytes32 digest = getBuildOnBehalfOfDigest(
            collateral, leverage, type(uint256).max, FIXED_NONCE, uint48(block.timestamp + 3600), true, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Get initial balances
        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        vm.prank(automator);
        shiva.limitOrderBuild(
            ShivaStructs.Build(ovlMarket, 0, true, collateral, leverage, type(uint256).max),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );

        // Check that keeper received the fee
        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee");
    }

    /**
     * @dev Test that take profit with keeper fee calculates and pays the fee correctly
     */
    function test_takeProfit_with_keeper_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(0.2e16); // 0.2%
        vm.stopPrank();

        // First build a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        vm.stopPrank();

        // Use a safe price limit
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        // Get digest and signature for unwind on behalf of
        bytes32 digest = getUnwindOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, uint48(block.timestamp + 3600), 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Record balances before
        uint256 keeperBalanceBefore = ovlToken.balanceOf(charlie);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        // Give keeper gas money
        vm.deal(charlie, 1 ether);

        vm.startPrank(charlie);
        shiva.takeProfit(
            ShivaStructs.Unwind(ovlMarket, 0, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );
        vm.stopPrank();

        // Check that keeper received the fee
        uint256 keeperBalanceAfter = ovlToken.balanceOf(charlie);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee");
    }

    /**
     * @dev Test that unwind reverts if the unwind amount is insufficient to pay the keeper fee
     */
    function test_revert_unwind_insufficient_for_fee() public {
        // Set a high keeper incentive that likely won't be covered
        uint256 highIncentive = 50000e18; // 5000000%, absurdly high
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(highIncentive);
        vm.stopPrank();

        // Build a small position
        vm.startPrank(alice);
        uint256 posId = buildPosition(10e18, 1e18, 1, true); // small 10 OVL position
        vm.stopPrank();

        // Use a safe price limit
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        // Get digest and signature for unwind on behalf of
        bytes32 digest = getUnwindOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, uint48(block.timestamp + 3600), 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Give keeper gas money to avoid out-of-gas issues
        vm.deal(bob, 1 ether);

        // Expect revert when unwinding
        vm.startPrank(bob);
        try shiva.takeProfit(
            ShivaStructs.Unwind(ovlMarket, 0, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        ) {
            revert("Transaction did not revert as expected");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IShiva.InsufficientUnwindAmountForFee.selector, 9942478705580122309, 131030620560000000000), "Incorrect error");
        }
        vm.stopPrank();
    }

    /**
     * @dev Test that buildSingle with keeper fee calculates and pays the fee correctly
     */
    function test_buildSingle_with_keeper_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(0.3e16); // 0.3%
        vm.stopPrank();

        // Bob builds a position
        vm.startPrank(bob);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        vm.stopPrank();

        uint256 newCollateral = 50e18;
        uint256 leverage = 2e18;

        // Prepare parameters for Bob's buildSingle transaction
        uint256 unwindPriceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);
        uint256 estimatedTotalCollateral = newCollateral + 100e18;
        uint256 buildPriceLimit = Utils.getEstimatedPrice(
            ovlState, ovlMarket, estimatedTotalCollateral, leverage, BASIC_SLIPPAGE, true
        );
        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            newCollateral,
            leverage,
            posId,
            FIXED_NONCE,
            unwindPriceLimit,
            buildPriceLimit,
            uint48(block.timestamp + 3600),
            0
        );
        bytes memory signature = getSignature(digest, bobPk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        // Automator executes the transaction for Bob
        vm.startPrank(automator);
        shiva.buildSingle(
            ShivaStructs.BuildSingle(
                ovlMarket, 0, unwindPriceLimit, buildPriceLimit, newCollateral, leverage, posId
            ),
            ShivaStructs.OnBehalfOf(bob, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            true // payKeeperFee
        );
        vm.stopPrank();

        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee");
    }

    /**
     * @dev Test that when payKeeperFee is false, no fee is paid
     */
    function test_no_keeper_fee_when_false() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(10e16); // 10%
        vm.stopPrank();

        // Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint256 newCollateral = 50e18;
        uint256 leverage = 2e18;

        uint256 unwindPriceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);
        uint256 estimatedTotalCollateral = newCollateral + 100e18;
        uint256 buildPriceLimit = Utils.getEstimatedPrice(
            ovlState, ovlMarket, estimatedTotalCollateral, leverage, BASIC_SLIPPAGE, true
        );

        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            newCollateral,
            leverage,
            posId,
            FIXED_NONCE,
            unwindPriceLimit,
            buildPriceLimit,
            uint48(block.timestamp + 3600),
            0
        );
        bytes memory signature = getSignature(digest, alicePk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(bob);

        // Bob executes the transaction for Alice
        vm.startPrank(bob);
        shiva.buildSingle(
            ShivaStructs.BuildSingle(
                ovlMarket, 0, unwindPriceLimit, buildPriceLimit, newCollateral, leverage, posId
            ),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            false // payKeeperFee
        );
        vm.stopPrank();

        uint256 keeperBalanceAfter = ovlToken.balanceOf(bob);
        assertEq(keeperBalanceAfter, keeperBalanceBefore, "Keeper should not receive fee");
    }

    /**
     * @dev Test that stop loss with keeper fee calculates and pays the fee correctly
     */
    function test_stopLoss_with_keeper_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(0.1e16); // 0.1%
        vm.stopPrank();

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

        bytes32 digest = getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, 0);
        bytes memory signature = getSignature(digest, alicePk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);
        vm.deal(automator, 1 ether); // give gas money

        // Automator executes the transaction for Alice
        vm.startPrank(automator);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true);
        vm.stopPrank();
        
        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee");
    }

    /**
     * @dev Test that stop loss does not pay a fee when payKeeperFee is false
     */
    function test_stopLoss_no_keeper_fee_when_false() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(10e16); // 10% incentive
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
        
        bytes32 digest = getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, 0);
        bytes memory signature = getSignature(digest, alicePk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(bob);
        vm.deal(bob, 1 ether);

        // Bob executes the transaction for Alice with payKeeperFee = false
        vm.startPrank(bob);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
        vm.stopPrank();

        uint256 keeperBalanceAfter = ovlToken.balanceOf(bob);
        assertEq(keeperBalanceAfter, keeperBalanceBefore, "Keeper should not receive a fee");
    }

    /**
     * @dev Test that limitOrderBuild reverts if the user has insufficient balance for the keeper fee.
     */
    function test_revert_limitOrderBuild_insufficient_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(10e16); // 10%
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;
        uint256 notional = collateral.mulUp(leverage);
        uint256 tradingFee = notional.mulUp(ovlMarket.params(uint256(Risk.Parameters.TradingFeeRate)));
        uint256 aliceBalance = collateral + tradingFee; // Just enough for collateral and trading fee

        // Set Alice's balance precisely
        deal(address(ovlToken), alice, aliceBalance);
        
        // Get digest and signature for build on behalf of
        bytes32 digest = getBuildOnBehalfOfDigest(
            collateral, leverage, type(uint256).max, FIXED_NONCE, uint48(block.timestamp + 3600), true, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        vm.deal(automator, 1 ether); // give gas money
        vm.prank(automator);
        
        // Expect a revert because Alice's balance is insufficient to pay the additional keeper fee
        vm.expectRevert();
        shiva.limitOrderBuild(
            ShivaStructs.Build(ovlMarket, 0, true, collateral, leverage, type(uint256).max),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );
    }

    /**
     * @dev Test that buildSingle reverts if the user has insufficient balance for the keeper fee.
     */
    function test_revert_buildSingle_insufficient_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(10e16); // 10%
        vm.stopPrank();

        // Bob builds an initial position
        vm.startPrank(bob);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        vm.stopPrank();

        uint256 newCollateral = 50e18;
        uint256 leverage = 2e18;

        // Estimate the trading fee for the buildSingle operation.
        // It's based on the total collateral (new + unwound from previous position).
        // Assuming PnL is negligible, unwound amount is ~100 OVL.
        uint256 estimatedUnwoundAmount = 100e18;
        uint256 totalCollateral = newCollateral + estimatedUnwoundAmount;
        uint256 notional = totalCollateral.mulUp(leverage);
        uint256 tradingFee = notional.mulUp(ovlMarket.params(uint256(Risk.Parameters.TradingFeeRate)));
        
        // Set Bob's balance to exactly cover the new collateral and the calculated trading fee
        uint256 bobBalance = newCollateral + tradingFee;
        deal(address(ovlToken), bob, bobBalance);

        // Prepare parameters for Bob's buildSingle transaction
        uint256 unwindPriceLimit = Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);
        uint256 buildPriceLimit = Utils.getEstimatedPrice(ovlState, ovlMarket, totalCollateral, leverage, BASIC_SLIPPAGE, true);
        
        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            newCollateral,
            leverage,
            posId,
            FIXED_NONCE,
            unwindPriceLimit,
            buildPriceLimit,
            uint48(block.timestamp + 3600),
            0
        );
        bytes memory signature = getSignature(digest, bobPk);

        vm.deal(automator, 1 ether); // give gas money
        vm.prank(automator);

        // Expect a revert because Bob's balance is insufficient to pay the additional keeper fee
        vm.expectRevert();
        shiva.buildSingle(
            ShivaStructs.BuildSingle(
                ovlMarket, 0, unwindPriceLimit, buildPriceLimit, newCollateral, leverage, posId
            ),
            ShivaStructs.OnBehalfOf(bob, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            true // payKeeperFee
        );
    }

    /**
     * @dev Test that take profit with a partial unwind still pays the keeper fee correctly.
     */
    function test_takeProfit_partial_unwind_with_keeper_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(0.2e16); // 0.2%
        vm.stopPrank();

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
        bytes32 digest = getUnwindOnBehalfOfDigest(
            posId, fractionToUnwind, priceLimit, FIXED_NONCE, uint48(block.timestamp + 3600), 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Record balances before
        uint256 keeperBalanceBefore = ovlToken.balanceOf(charlie);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        // Give keeper gas money
        vm.deal(charlie, 1 ether);

        vm.startPrank(charlie);
        shiva.takeProfit(
            ShivaStructs.Unwind(ovlMarket, 0, posId, fractionToUnwind, priceLimit),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );
        vm.stopPrank();

        // Check that keeper received the fee
        uint256 keeperBalanceAfter = ovlToken.balanceOf(charlie);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive a fee for partial unwind");
    }

    /**
     * @dev Test that keeper fee is still paid when keeper incentive is zero (covers base gas cost).
     */
    function test_fee_with_zero_keeper_incentive() public {
        // Set keeper incentive to zero
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(0);
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;

        // Get digest and signature for build on behalf of
        bytes32 digest = getBuildOnBehalfOfDigest(
            collateral, leverage, type(uint256).max, FIXED_NONCE, uint48(block.timestamp + 3600), true, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Get initial balances
        uint256 keeperBalanceBefore = ovlToken.balanceOf(automator);
        assertEq(keeperBalanceBefore, 0, "Keeper should have no OVL initially");

        vm.deal(automator, 1 ether);
        vm.prank(automator);
        shiva.limitOrderBuild(
            ShivaStructs.Build(ovlMarket, 0, true, collateral, leverage, type(uint256).max),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );

        // Check that keeper received a fee (the base gas cost reimbursement)
        uint256 keeperBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(keeperBalanceAfter, keeperBalanceBefore, "Keeper should receive base gas fee even with zero incentive");
    }

    /**
     * @dev Test that stopLoss reverts if the unwind amount is insufficient to pay the keeper fee.
     */
    function test_revert_stopLoss_insufficient_for_fee() public {
        // Set an absurdly high keeper incentive
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(50000e18); // 5000000%
        vm.stopPrank();

        // Alice builds a small position
        vm.startPrank(alice);
        uint256 posId = buildPosition(10e18, 1e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Trigger stop loss condition
        IOverlayV1ChainlinkFeed marketFeed = IOverlayV1ChainlinkFeed(ovlMarket.feed());
        Oracle.Data memory oracleData = marketFeed.latest();
        uint256 currentBidPrice = ovlMarket.bid(oracleData, 0);
        uint256 triggerPrice = currentBidPrice * 101 / 100;

        IFluxAggregator marketAggregator = IFluxAggregator(marketFeed.aggregator());
        address oracle = marketAggregator.getOracles()[0];
        int256 newOraclePrice = int256(triggerPrice * 95 / 100);
        newOraclePrice /= 1e10; // Scale down for mock

        vm.startPrank(oracle);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.warp(block.timestamp + 3600);
        marketAggregator.submit(marketAggregator.latestRound() + 1, newOraclePrice);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 3600);
        bytes32 digest = getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, 0, deadline, FIXED_NONCE, 0);
        bytes memory signature = getSignature(digest, alicePk);
        
        vm.deal(automator, 1 ether);
        vm.startPrank(automator);

        // Expect revert due to insufficient amount to pay the massive fee
        try shiva.stopLoss(
            ShivaStructs.StopLoss(ovlMarket, 0, posId, ONE, triggerPrice, 0),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            true
        ) {
            // If the transaction does not revert, fail the test.
            fail();
        } catch {
            // An empty catch block signifies that we expect any revert, which is sufficient here.
        }
        vm.stopPrank();
    }

    /**
     * @dev Test that takeProfit succeeds even on an unprofitable unwind, as long as the fee is covered.
     */
    function test_takeProfit_unprofitable_unwind_with_fee() public {
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(0.2e16); // 0.2%
        vm.stopPrank();

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

        bytes32 digest = getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, FIXED_NONCE, deadline, 0);
        bytes memory signature = getSignature(digest, alicePk);

        uint256 keeperBalanceBefore = ovlToken.balanceOf(charlie);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        vm.deal(charlie, 1 ether);

        vm.startPrank(charlie);
        shiva.takeProfit(
            ShivaStructs.Unwind(ovlMarket, 0, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature)
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
        shiva.setNativeOvlFeed(badFeed);
        vm.stopPrank();
        
        // Prepare a standard limitOrderBuild call
        uint256 collateral = 100e18;
        uint256 leverage = 2e18;
        bytes32 digest = getBuildOnBehalfOfDigest(
            collateral, leverage, type(uint256).max, FIXED_NONCE, uint48(block.timestamp + 3600), true, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        vm.deal(automator, 1 ether);
        vm.prank(automator);
        
        // The call should revert because nativeOvlFeed.latest() will fail internally
        vm.expectRevert("No data present");
        shiva.limitOrderBuild(
            ShivaStructs.Build(ovlMarket, 0, true, collateral, leverage, type(uint256).max),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );
    }
} 