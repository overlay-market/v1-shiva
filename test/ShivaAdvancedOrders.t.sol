// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ShivaTestBase} from "./ShivaBase.t.sol";
import {IShiva} from "src/IShiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {IOverlayV1Feed} from "v1-core/contracts/interfaces/feeds/IOverlayV1Feed.sol";
import {Oracle} from "v1-core/contracts/libraries/Oracle.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {IOverlayV1ChainlinkFeed} from "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";
import {Utils} from "../src/utils/Utils.sol";

/**
 * @title ShivaAdvancedOrdersTest
 * @notice Test suite for advanced order types in the Shiva contract
 */
contract ShivaAdvancedOrdersTest is Test, ShivaTestBase {
    using FixedPoint for uint256;

    // =================================================================
    //
    //                       SETUP
    //
    // =================================================================

    uint256 internal constant WARM_UP_PERIOD = 1 hours;
    uint256 internal constant NUM_WARM_UP_ROUNDS = 5;
    MockAggregator badNativeAggregator;

    /**
     * @dev Sets up the initial state for the test contract
     */
    function setUp() public override {
        super.setUp();
        vm.fee(10 gwei); // Set a base fee for the block to enable dynamic fee calculation
        aggregator.addOracle(address(this));
        // Warm up the oracle to ensure sufficient data for TWAP calculations
        _warmUpOracle(IOverlayV1Feed(ovlMarket.feed()));
    }

    // =================================================================
    //
    //                       STOP-LOSS TESTS
    //
    // =================================================================

    /**
     * @notice Tests that stop loss on behalf of fails due to an expired deadline
     */
    function testStopLossOnBehalfOfExpiredDeadline() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp - 3600); // expired deadline

        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId,
            ONE,
            triggerPrice,
            priceLimit,
            deadline,
            FIXED_NONCE,
            BROKER_ID,
            false,
            0
        );

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        vm.prank(automator);
        stopLossOnBehalfOf(
            posId,
            ONE,
            triggerPrice,
            priceLimit,
            deadline,
            signature,
            alice,
            false, // payRelayerFee
            0
        );
    }

    /**
     * @notice Tests that a stop loss order for a long position executes when the price drops,
     *         and the relayer receives a fee.
     */
    function testStopLossOnBehalfOfLongPositionExecutesWithFee() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true); // 1 OVL collateral, 5x leverage
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        // We get the price from the market's perspective to set a realistic trigger
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100; // 5% price drop
        uint256 priceLimit = triggerPrice * 99 / 100; // 1% slippage tolerance for the unwind
        uint48 deadline = uint48(block.timestamp + 3600); // 1 hour deadline

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, true, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before trigger, should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        stopLossOnBehalfOf(
            posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true, type(uint256).max
        );
        vm.stopPrank();

        // 4. Price drops, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 999 / 1000; // Price drops just below the trigger
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60); // Advance time to ensure oracle update

        // 5. Automator executes the stop-loss order successfully and gets paid
        vm.startPrank(automator);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);
        stopLossOnBehalfOf(
            posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true, type(uint256).max
        );
        uint256 automatorBalanceAfter = ovlToken.balanceOf(automator);
        vm.stopPrank();

        // 6. Verify position is closed
        assertFractionRemainingIsZero(address(shiva), posId);

        // 7. Verify relayer received a fee
        assertGt(automatorBalanceAfter, automatorBalanceBefore, "Relayer should have received a fee");
    }

    /**
     * @notice Tests that a stop loss order for a short position executes when the price rises,
     *         and the relayer does NOT receive a fee.
     */
    function testStopLossOnBehalfOfShortPositionExecutesWithoutFee() public {
        // 1. Alice builds a short position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, false); // 1 OVL collateral, 5x leverage, short
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0); // Use ask for short positions

        uint256 triggerPrice = currentPrice * 105 / 100; // 5% price rise
        uint256 priceLimit = triggerPrice * 101 / 100; // 1% slippage tolerance for the unwind
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before trigger, should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();

        // 4. Price rises, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 1001 / 1000; // Price rises just above the trigger
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60); // Advance time

        // 5. Automator executes the stop-loss order successfully (no fee)
        vm.startPrank(automator);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        uint256 automatorBalanceAfter = ovlToken.balanceOf(automator);
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        vm.stopPrank();

        // 6. Verify position is closed
        assertFractionRemainingIsZero(address(shiva), posId);

        // 7. Verify Alice received her funds back
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received her funds back");

        // 8. Verify relayer did not receive a fee
        assertEq(automatorBalanceAfter, automatorBalanceBefore, "Relayer should not have received a fee");
    }

    /**
     * @notice Tests that stop loss on behalf of fails due to invalid parameters.
     */
    function testStopLossOnBehalfOfInvalidParams() public {
        // 1. Alice builds a long position and another one to use as a wrong parameter
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        uint256 otherPosId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        vm.startPrank(automator);

        // 3. Try to execute with different parameters, all should revert with InvalidSignature
        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(
            otherPosId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0
        );

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(
            posId, ONE / 2, triggerPrice, priceLimit, deadline, signature, alice, false, 0
        );

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(
            posId, ONE, triggerPrice + 1, priceLimit, deadline, signature, alice, false, 0
        );

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(
            posId, ONE, triggerPrice, priceLimit + 1, deadline, signature, alice, false, 0
        );

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline + 1, signature, alice, false, 0);

        // Different brokerId
        vm.expectRevert(IShiva.InvalidSignature.selector);
        shiva.stopLoss(
            ShivaStructs.StopLoss(
                ovlMarket, BROKER_ID + 1, false, posId, ONE, priceLimit, triggerPrice, 0
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature)
        );

        // Different market - this reverts with NotPositionOwner because the check happens before the signature validation
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        shiva.stopLoss(
            ShivaStructs.StopLoss(
                otherOvlMarket, BROKER_ID, false, posId, ONE, priceLimit, triggerPrice, 0
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature)
        );

        vm.stopPrank();
    }

    /**
     * @notice Tests that stop loss on behalf of fails due to an invalid signature (bad owner).
     */
    function testStopLossOnBehalfOfInvalidSignatureBadOwner() public {
        // 1. Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. A stop-loss order is created for Alice's position
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);

        // 3. Bob signs the digest instead of Alice
        bytes memory signature = getSignature(digest, bobPk);

        // 4. Automator tries to execute on behalf of Alice with Bob's signature, which should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that stop loss on behalf of fails due to an invalid signature (bad nonce).
     */
    function testStopLossOnBehalfOfInvalidSignatureBadNonce() public {
        // 1. Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order with a different nonce
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;

        // Note the different nonce used for the digest
        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE + 1, BROKER_ID, false, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute. The call inside `stopLossOnBehalfOf` uses `FIXED_NONCE`,
        // so the signature won't match.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that stop loss on behalf of fails due to a used nonce.
     */
    function testStopLossOnBehalfOfUsedNonce() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);
        uint256 triggerPrice = currentPrice * 95 / 100;
        uint256 priceLimit = triggerPrice * 99 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the stop-loss order successfully
        vm.startPrank(automator);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);

        // 5. Automator tries to execute the same order again, should fail due to used nonce
        vm.expectRevert(IShiva.InvalidNonce.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that stop loss on behalf of fails due to a canceled nonce.
     */
    function testStopLossOnBehalfOfCancelledNonce() public {
        // 1. Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;
        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Alice cancels the nonce used in the signature
        vm.prank(alice);
        shiva.cancelNonce(FIXED_NONCE);

        // 4. Automator tries to execute, it should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidNonce.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that stop loss on behalf of fails when the contract is paused.
     */
    function testStopLossOnBehalfOfPausedShiva() public {
        // 1. Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;
        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. The contract is paused
        pauseShiva();

        // 4. Automator tries to execute, it should fail
        vm.startPrank(automator);
        vm.expectRevert("Pausable: paused");
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that stop loss on behalf of fails if the signer is not the position owner.
     */
    function testStopLossOnBehalfOfNotPositionOwner() public {
        // 1. Alice builds a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Bob signs a stop-loss order for Alice's position
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;
        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, bobPk);

        // 3. Automator tries to execute on behalf of Bob for Alice's position, should fail ownership check
        vm.startPrank(automator);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, bob, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests a partial stop loss unwind.
     */
    function testStopLossOnBehalfOfPartialUnwind() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order for 50% of the position
        uint256 fractionToUnwind = 0.5e18;
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);
        uint256 triggerPrice = currentPrice * 95 / 100;
        uint256 priceLimit = triggerPrice * 99 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, fractionToUnwind, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the partial stop-loss
        vm.startPrank(automator);
        stopLossOnBehalfOf(
            posId, fractionToUnwind, triggerPrice, priceLimit, deadline, signature, alice, false, 0
        );
        vm.stopPrank();

        // 5. Verify position is partially closed (approximately 50% remaining)
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertApproxEqAbs(fractionRemaining, 5000, 10); // 5000 is 50% in basis points (1e16)
    }

    /**
     * @notice Tests that a stop loss order reverts if the execution price is worse than the price limit.
     */
    function testStopLossRevertsIfPriceLimitBreached() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, BASIC_SLIPPAGE, true); // 100 OVL collateral, 2x leverage
        vm.stopPrank();

        // 2. Alice signs a stop-loss order with a trigger and a price limit
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100; // 5% price drop
        uint256 priceLimit = triggerPrice * 99 / 100; // 1% slippage tolerance for the unwind
        uint48 deadline = uint48(block.timestamp + 4 hours); // 4 hour deadline to account for time warps

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops significantly, below both the trigger price and the price limit
        uint256 executionPrice = priceLimit * 98 / 100; // Price drops 2% below the user's limit (less aggressive)
        // Submit multiple price updates to ensure oracle has sufficient data
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator attempts to execute the stop-loss order
        // It should fail because the current price is worse than the user's priceLimit.
        // The exact revert message comes from the OverlayV1Market contract.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max");
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();

        // 5. Verify position is NOT closed
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0, "Position should not have been closed");
    }

    /**
     * @notice Tests that stop loss reverts if the remaining collateral after unwind is less than the relayer fee.
     */
    /* function testStopLossRevertsIfRemainingCollateralIsLessThanRelayerFee() public {
        // 1. Set a high keeper incentive to make the fee significant
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(50000e18); // 5,000,000% incentive, high enough to trigger the revert
        vm.stopPrank();

        // 2. Alice builds a small long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(10e18, 2e18, BASIC_SLIPPAGE, true); // 10 OVL, 2x leverage
        vm.stopPrank();

        // 3. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 90 / 100; // 10% price drop
        uint256 priceLimit = 0; // Accept any price
        uint48 deadline = uint48(block.timestamp + 4 hours);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, true, type(uint256).max);
        bytes memory signature = getSignature(digest, alicePk);

        // 4. Price drops significantly, causing a large loss and triggering the stop loss
        uint256 executionPrice = triggerPrice * 80 / 100; // 20% further drop, nearly wiping out the position
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));

        // 5. Automator executes the stop-loss order
        // The transaction is expected to revert because the unwound amount is insufficient to pay the fee.
        vm.startPrank(automator);
        vm.expectRevert(
            abi.encodeWithSelector(IShiva.InsufficientUnwindAmountForFee.selector, 3839819857403767165, 155216104260000000000)
        );
        shiva.stopLoss(
            ShivaStructs.StopLoss(
                ovlMarket, BROKER_ID, true, posId, ONE, priceLimit, triggerPrice, type(uint256).max
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature)
        );
        vm.stopPrank();
    } */

    /**
     * @notice Tests that a stop loss signature is invalidated after the position is closed via buildSingle.
     */
    function testStopLossSignatureIsInvalidatedAfterBuildSingle() public {
        // 1. Alice builds an initial position
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(100e18, 2e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order for the initial position
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);
        uint256 triggerPrice = currentPrice * 95 / 100; // 5% drop
        uint48 deadline = uint48(block.timestamp + 3600);
        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId1, ONE, triggerPrice, 0, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Alice uses buildSingle to close posId1 and open posId2
        vm.startPrank(alice);
        uint256 unwindPriceLimit = 0; // accept any price for the unwind part of buildSingle
        uint256 buildPriceLimit = type(uint256).max; // accept any price for the build part
        uint256 newCollateral = 50e18;
        uint256 newLeverage = 3e18;

        buildSinglePosition(newCollateral, newLeverage, posId1, unwindPriceLimit, buildPriceLimit);
        vm.stopPrank();

        // 4. Verify the initial position is now closed
        assertFractionRemainingIsZero(address(shiva), posId1);

        // 5. Price drops, which would have triggered the original stop loss
        uint256 executionPrice = triggerPrice * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 6. Automator attempts to execute the original stop loss for posId1.
        // This must fail because the position has already been closed.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:!position"); // Reverts from market because position no longer exists
        stopLossOnBehalfOf(posId1, ONE, triggerPrice, 0, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that a long position stop-loss is specifically triggered by the market's bid price.
     */
    function testStopLossLongPositionTriggeredByBidPrice() public {
        // 1. Alice builds a long position.
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Define a trigger price 5% below the current bid price.
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentBidPrice = ovlMarket.bid(data, 0);
        uint256 triggerPrice = currentBidPrice * 95 / 100;
        uint256 priceLimit = triggerPrice * 99 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Manipulate the oracle so the new bid price is just ABOVE the trigger.
        // The stop-loss should NOT execute.
        // We set the oracle price to be slightly higher than the trigger price.
        // Since bid_price <= oracle_price, this isn't guaranteed to place the bid above,
        // but for a small spread it should. We will adjust if needed.
        uint256 targetOraclePrice = triggerPrice * 101 / 100; // 1% above trigger

        aggregator.submit(aggregator.latestRound() + 1, int256(targetOraclePrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // Sanity check and adjustment loop to ensure test setup is correct.
        // This makes the test robust against different spread configurations.
        data = feed.latest();
        uint256 newBidPrice = ovlMarket.bid(data, 0);
        while (newBidPrice <= triggerPrice) {
            targetOraclePrice = targetOraclePrice * 101 / 100;
            aggregator.submit(aggregator.latestRound() + 1, int256(targetOraclePrice / 1e10));
            vm.warp(block.timestamp + 60 * 60);
            data = feed.latest();
            newBidPrice = ovlMarket.bid(data, 0);
        }

        deadline = uint48(block.timestamp + 3600); // Re-set deadline after time manipulation
        // Re-sign the digest with the new deadline
        digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        signature = getSignature(digest, alicePk);

        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();

        // 4. Now, manipulate the oracle so the new bid price is just BELOW the trigger.
        // The stop-loss SHOULD execute. We set the oracle price directly to the trigger price.
        // The bid price will be <= oracle price, ensuring it's below the trigger.
        targetOraclePrice = triggerPrice;
        aggregator.submit(aggregator.latestRound() + 1, int256(targetOraclePrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // Sanity check: verify the new bid is now below the trigger.
        data = feed.latest();
        newBidPrice = ovlMarket.bid(data, 0);
        assertLt(newBidPrice, triggerPrice, "Test setup failed: new bid price should be < trigger");

        deadline = uint48(block.timestamp + 3600); // Re-set deadline after time manipulation
        // Re-sign the digest with the new deadline
        digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        signature = getSignature(digest, alicePk);

        vm.startPrank(automator);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();

        // 5. Verify the position is now closed.
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    /**
     * @notice Tests that a stop loss order fails if the position was already closed manually.
     */
    function testStopLossFailsOnManuallyClosedPosition() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100; // 5% price drop
        uint256 priceLimit = triggerPrice * 99 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Alice manually closes her position before the stop loss triggers
        vm.startPrank(alice);
        unwindPosition(posId, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        // 4. Verify the position is indeed closed
        assertFractionRemainingIsZero(address(shiva), posId);

        // 5. Price drops, making the original stop-loss signature executable
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 6. Automator attempts to execute the stop-loss, which should fail
        // because the underlying market position no longer exists.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:!position"); // Reverts from market because position no longer exists
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that stop loss fails if the market is shut down.
     */
    function testStopLossFailsWhenMarketIsShutdown() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100;
        uint256 priceLimit = triggerPrice * 99 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. The market is shut down
        shutDownMarket();

        // 4. Price drops, which would normally make the stop-loss executable
        aggregator.submit(aggregator.latestRound() + 1, int256(triggerPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 5. Automator attempts to execute the stop-loss, which should fail
        // because the market is shut down.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1: shutdown"); // Reverts from market because market is shut down
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();
    }

    /**
     * @notice Tests that a stop loss for a long position executes exactly at the trigger price.
     */
    function testStopLossExecutesAtExactTriggerPrice() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100; // 5% price drop
        uint256 priceLimit = triggerPrice * 99 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops to be exactly the trigger price
        aggregator.submit(aggregator.latestRound() + 1, int256(triggerPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the stop-loss order successfully
        vm.startPrank(automator);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();

        // 5. Verify position is closed
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    /**
     * @notice Tests that a stop-loss executes at a price worse than trigger but within the price limit, due to a price gap.
     */
    function testStopLossExecutesWithSignificantSlippageWithinLimit() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100; // Trigger at 5% drop
        uint256 priceLimit = triggerPrice * 98 / 100; // Allow up to 2% slippage from trigger
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price gaps down to a level between the trigger and the limit
        uint256 executionPrice = triggerPrice * 99 / 100; // 1% slippage, which is within the 2% limit
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the stop-loss order
        vm.startPrank(automator);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        vm.stopPrank();

        // 5. Verify position is closed
        assertFractionRemainingIsZero(address(shiva), posId);

        // 6. Verify Alice received her funds back (minus the loss)
        // This is a sanity check to ensure the unwind logic processed correctly, even with high slippage.
        // A direct calculation of expected return is complex due to market dynamics,
        // so we check that she received *something* back and the amount is positive.
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received the remaining collateral");
    }

    /**
     * @notice Tests that the directional trigger for stop-loss orders executes correctly for both long and short positions.
     */
    function testStopLossDirectionalTriggerExecutesCorrectly() public {
        // Scenario 1: Long position. Stop-loss should trigger on a price DROP.
        vm.startPrank(alice);
        uint256 longPosId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentBidPrice = ovlMarket.bid(data, 0);

        // 1a. Set a trigger price 5% BELOW the current price.
        uint256 triggerPriceLong = currentBidPrice * 95 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 priceLimit = triggerPriceLong * 99 / 100; // 1% slippage tolerance

        bytes32 digestLong = getStopLossOnBehalfOfDigest(
            longPosId, ONE, triggerPriceLong, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        bytes memory signatureLong = getSignature(digestLong, alicePk);

        // 1b. Try to execute when price is still ABOVE the trigger. Should fail.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        stopLossOnBehalfOf(longPosId, ONE, triggerPriceLong, priceLimit, deadline, signatureLong, alice, false, 0);
        vm.stopPrank();

        // 1c. Drop the price BELOW the trigger. Should now execute successfully.
        uint256 newExecutionPrice = triggerPriceLong * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(newExecutionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        vm.startPrank(automator);
        stopLossOnBehalfOf(longPosId, ONE, triggerPriceLong, priceLimit, deadline, signatureLong, alice, false, 0);
        vm.stopPrank();

        assertFractionRemainingIsZero(address(shiva), longPosId);

        // Scenario 2: Short position. Stop-loss should trigger on a price RISE.
        vm.startPrank(alice);
        uint256 shortPosId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, false);
        vm.stopPrank();

        uint256 nonceShort = FIXED_NONCE + 1;
        deadline = uint48(block.timestamp + 3600); // Re-set deadline for the second scenario
        data = feed.latest();
        uint256 currentAskPrice = ovlMarket.ask(data, 0);

        // 2a. Set a trigger price 5% ABOVE the current price.
        uint256 triggerPriceShort = currentAskPrice * 105 / 100;
        priceLimit = triggerPriceShort * 101 / 100; // 1% slippage tolerance

        bytes32 digestShort = getStopLossOnBehalfOfDigest(
            shortPosId, ONE, triggerPriceShort, priceLimit, deadline, nonceShort, BROKER_ID, false, 0
        );
        bytes memory signatureShort = getSignature(digestShort, alicePk);

        // 2b. Try to execute when price is still BELOW the trigger. Should fail.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        shiva.stopLoss(
            ShivaStructs.StopLoss(
                ovlMarket, BROKER_ID, false, shortPosId, ONE, priceLimit, triggerPriceShort, 0
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, nonceShort, signatureShort)
        );
        vm.stopPrank();

        // 2c. Rise the price ABOVE the trigger. Should now execute successfully.
        newExecutionPrice = triggerPriceShort * 1001 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(newExecutionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        vm.startPrank(automator);
        shiva.stopLoss(
            ShivaStructs.StopLoss(
                ovlMarket, BROKER_ID, false, shortPosId, ONE, priceLimit, triggerPriceShort, 0
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, nonceShort, signatureShort)
        );
        vm.stopPrank();

        assertFractionRemainingIsZero(address(shiva), shortPosId);
    }

    /**
     * @notice Tests that a stop loss order for a short position reverts if the execution price is worse than the price limit.
     */
    function testStopLossRevertsIfPriceLimitBreachedShort() public {
        // 1. Alice builds a short position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, BASIC_SLIPPAGE, false); // 100 OVL collateral, 2x leverage, short
        vm.stopPrank();

        // 2. Alice signs a stop-loss order with a trigger and a price limit
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);

        uint256 triggerPrice = currentPrice * 105 / 100; // 5% price rise
        uint256 priceLimit = triggerPrice * 101 / 100; // 1% slippage tolerance (higher is worse for shorts)
        uint48 deadline = uint48(block.timestamp + 4 hours); // 4 hour deadline to account for time warps

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID, false, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price rises significantly, above both the trigger price and the price limit
        uint256 executionPrice = priceLimit * 105 / 100; // Price jumps 5% beyond the user's limit
        // Submit multiple price updates to ensure oracle has sufficient data
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator attempts to execute the stop-loss order
        // It should fail because the current price is worse (higher) than the user's priceLimit.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max"); // Reverts from market because price exceeds slippage limit
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false, 0);
        vm.stopPrank();

        // 5. Verify position is NOT closed
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0, "Position should not have been closed");
    }

    // =================================================================
    //
    //                       TAKE-PROFIT TESTS
    //
    // =================================================================

    /**
     * @notice Tests that a take-profit order for a long position executes when the price rises.
     *         The order is a standard unwind signed by the user with a favorable priceLimit.
     */
    function testTakeProfitOnBehalfOfLongPositionExecutes() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true); // 1 OVL collateral, 5x leverage
        vm.stopPrank();

        // 2. Alice signs a take-profit order (an unwind with a high price limit)
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0); // Use bid for unwinding a long

        // Take profit if price increases by 5%. This is our price limit.
        uint256 priceLimit = currentPrice * 105 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before price target is met. Should fail.
        // The market will revert because the current execution price is less than the priceLimit.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max"); // Reverts from market because price is below slippage limit
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // 4. Price rises, making the take-profit executable
        uint256 executionPrice = priceLimit * 101 / 100; // Price rises above the limit
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60); // Advance time

        // 5. Automator executes the take-profit order successfully and gets paid
        vm.startPrank(automator);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);

        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );

        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        uint256 automatorBalanceAfter = ovlToken.balanceOf(automator);
        vm.stopPrank();

        // 6. Verify position is closed and balances are correct
        assertFractionRemainingIsZero(address(shiva), posId);
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received her profits");
        assertGt(automatorBalanceAfter, automatorBalanceBefore, "Relayer should have received a fee");
    }

    /**
     * @notice Tests that a take-profit order reverts if the profit is less than the relayer fee.
     */
    /* function testTakeProfitRevertsIfProfitIsLessThanRelayerFee() public {
        // 1. Set a very high keeper incentive to make the fee significant
        vm.startPrank(deployer);
        shiva.setKeeperIncentive(50000e18); // 5,000,000% incentive
        vm.stopPrank();

        // 2. Alice builds a small long position that will have a very small gain or loss
        vm.startPrank(alice);
        uint256 posId = buildPosition(10e18, 2e18, BASIC_SLIPPAGE, true); // 10 OVL, 2x leverage
        vm.stopPrank();

        // 3. Price can move negligibly. The goal is just to have a small unwindAmount.

        // 4. Alice signs a take-profit order
        uint256 priceLimit = 0; // Accept any price to ensure the order can be executed
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getTakeProfitOnBehalfOfDigest(posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max);
        bytes memory signature = getSignature(digest, alicePk);

        // 5. Automator executes the take-profit order.
        // It's expected to revert because the unwound amount is insufficient for the massive fee.
        vm.startPrank(automator);
        // The exact values for the revert data will be filled in after the first failed run.
        vm.expectRevert(
            abi.encodeWithSelector(IShiva.InsufficientUnwindAmountForFee.selector, 9416028083704622524, 147083441610000000000)
        );
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, 0
        );
        vm.stopPrank();
    } */

    /**
     * @notice Tests that a take-profit order for a short position executes when the price falls.
     */
    function testTakeProfitOnBehalfOfShortPositionExecutes() public {
        // 1. Alice builds a short position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, false); // 1 OVL collateral, 5x leverage, short
        vm.stopPrank();

        // 2. Alice signs a take-profit order (an unwind with a low price limit)
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0); // Use ask for unwinding a short

        // Take profit if price decreases by 5%. This is our price limit.
        uint256 priceLimit = currentPrice * 95 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before price target is met. Should fail.
        // The market will revert because the current execution price is greater than the priceLimit.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max"); // Reverts from market because execution price > priceLimit for short
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // 4. Price falls, making the take-profit executable
        uint256 executionPrice = priceLimit * 99 / 100; // Price falls below the limit
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 5. Automator executes the take-profit order successfully (no fee for this test)
        vm.startPrank(automator);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);

        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );

        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        uint256 automatorBalanceAfter = ovlToken.balanceOf(automator);
        vm.stopPrank();

        // 6. Verify position is closed and balances are correct
        assertFractionRemainingIsZero(address(shiva), posId);
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received her profits");
        assertGt(automatorBalanceAfter, automatorBalanceBefore, "Relayer should have received a fee");
    }

    /**
     * @notice Tests that a partial take-profit order (50%) executes correctly.
     */
    function testPartialTakeProfitExecutes() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a partial take-profit order (50%)
        uint256 fractionToUnwind = 0.5e18;
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);
        uint256 priceLimit = currentPrice * 105 / 100; // 5% profit target
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, fractionToUnwind, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price rises, making the take-profit executable
        uint256 executionPrice = priceLimit * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the partial take-profit
        vm.startPrank(automator);
        takeProfitOnBehalfOf(
            posId, fractionToUnwind, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // 5. Verify position is partially closed (approximately 50% remaining)
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertApproxEqAbs(fractionRemaining, 5000, 10); // 5000 is 50% in basis points
    }

    /**
     * @notice Tests that a take-profit order fails if the price moves back below the limit before execution.
     */
    function testTakeProfitFailsIfPriceMovesUnfavorablyPastLimit() public {
        // 1. Alice builds a long position.
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a take-profit order with a price limit 5% above the current price.
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);
        uint256 priceLimit = currentPrice * 105 / 100;
        uint48 deadline = uint48(block.timestamp + 4 hours); // 4 hour deadline to account for time warps

        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price rises, making the take-profit order executable.
        uint256 executablePrice = priceLimit * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executablePrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // At this point, a keeper could execute the order successfully.

        // 4. Before the keeper executes, the price drops back below the priceLimit.
        uint256 unfavorablePrice = priceLimit * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(unfavorablePrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 5. Automator attempts to execute the order. It should now fail because the
        // execution price is less than the required priceLimit.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max"); // Reverts from market because price is below slippage limit
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // 6. Verify the position was not closed.
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0, "Position should not have been closed");
    }

    /**
     * @notice Tests that a take-profit order fails if the position was already closed manually.
     */
    function testTakeProfitFailsOnManuallyClosedPosition() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a take-profit order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);
        uint256 priceLimit = currentPrice * 105 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Alice manually closes her position before the take profit triggers
        vm.startPrank(alice);
        unwindPosition(posId, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        // 4. Verify the position is indeed closed
        assertFractionRemainingIsZero(address(shiva), posId);

        // 5. Price rises, making the original take-profit signature valid price-wise
        uint256 executionPrice = priceLimit * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 6. Automator attempts to execute the take-profit, which should fail
        // because the underlying market position no longer exists.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:!position"); // Reverts from market because position no longer exists
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a take-profit order fails if the nonce has already been used.
     */
    function testTakeProfitFailsWithUsedNonce() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a take-profit order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);
        uint256 priceLimit = currentPrice * 105 / 100;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price rises, making the take-profit executable
        uint256 executionPrice = priceLimit * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the order successfully
        vm.startPrank(automator);
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );

        // 5. Automator tries to execute the same order again, should fail due to used nonce
        vm.expectRevert(IShiva.InvalidNonce.selector);
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a take-profit order fails with an invalid signature.
     */
    function testTakeProfitFailsWithInvalidSignature() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. An invalid signature is created (e.g., signed by Bob)
        uint256 priceLimit = 0; // Accept any price
        uint48 deadline = uint48(block.timestamp + 1 hours);
        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, bobPk); // Signed by Bob

        // 3. Automator attempts to execute the take-profit with the invalid signature
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a take-profit order fails when the market is shut down.
     */
    function testTakeProfitFailsWhenMarketIsShutdown() public {
        // 1. Alice builds a long position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a valid take-profit order
        uint256 priceLimit = 0; // Accept any price
        uint48 deadline = uint48(block.timestamp + 1 hours);
        bytes32 digest = getTakeProfitOnBehalfOfDigest(
            posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. The market is shut down
        shutDownMarket();

        // 4. Automator attempts to execute the take-profit order
        // It should fail because the market is shut down.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1: shutdown"); // Reverts from market because market is shut down
        takeProfitOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @dev Warms up the oracle by advancing time and submitting prices to ensure the TWAP windows are populated.
     * @param _feed The price feed to warm up.
     */
    function _warmUpOracle(IOverlayV1Feed _feed) internal {
        uint256 macroWindow = _feed.macroWindow();
        uint256 microWindow = _feed.microWindow();
        uint256 warmUpDuration = 2 * macroWindow; // Warm up for two macro windows
        uint256 submissions = warmUpDuration / microWindow;

        for (uint256 i = 0; i < submissions; i++) {
            vm.warp(block.timestamp + microWindow);
            uint256 price = uint256(
                aggregator.latestAnswer() + int256(i * 1e6) // Slightly move price each round
            );
            aggregator.submit(aggregator.latestRound() + 1, int256(price));
        }

        // Advance time one more step to ensure the last submission is within the window
        vm.warp(block.timestamp + microWindow);
    }

    // =================================================================
    //
    //              LIMIT ORDER (via Build) TESTS
    //
    // =================================================================

    /**
     * @notice Tests that a limit order (via build) for a long position executes when the price drops.
     */
    function testLimitBuildLongExecutes() public {
        // 1. Define order parameters. Alice wants to buy if price drops 5%.
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0); // Use ask for buying

        // The priceLimit acts as the trigger. The build will only succeed if execution_price <= priceLimit.
        uint256 priceLimit = currentPrice * 95 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        // 2. Alice signs the `build` message.
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, priceLimit, FIXED_NONCE, deadline, true, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Keeper attempts to execute before price condition is met.
        // It should fail inside the market because the current execution price is > priceLimit.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max"); // Reverts from market because slippage exceeds maximum
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // 4. Simulate a price drop to make the order executable.
        // The new oracle price must be low enough that `oracle_price + spread < priceLimit`.
        uint256 executionPrice = priceLimit * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 5. Keeper executes the order successfully.
        vm.startPrank(automator);
        uint256 posId = limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // 6. Verify the position has been created successfully.
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    /**
     * @notice Tests that a limit order (via build) for a short position executes and pays a fee.
     */
    function testLimitBuildShortExecutesWithFee() public {
        // 1. Define order parameters. Alice wants to sell if price rises 5%.
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0); // Use bid for selling

        // For a short, the build will only succeed if execution_price >= priceLimit.
        uint256 priceLimit = currentPrice * 105 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        // 2. Alice signs the `build` message.
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, priceLimit, FIXED_NONCE, deadline, false, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Keeper attempts to execute before price condition is met.
        // It should fail inside the market because the current execution price is < priceLimit.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max"); // Reverts from market because execution price < priceLimit for short
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, false, signature, alice, type(uint256).max
        );
        vm.stopPrank();

        // 4. Simulate a price rise to make the order executable.
        // The new oracle price must be high enough that `oracle_price - spread > priceLimit`.
        uint256 executionPrice = priceLimit * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 5. Keeper executes the order successfully and gets paid.
        vm.startPrank(automator);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);
        uint256 posId = limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, false, signature, alice, type(uint256).max
        );
        uint256 automatorBalanceAfter = ovlToken.balanceOf(automator);
        vm.stopPrank();

        // 6. Verify position is created and relayer was paid.
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        assertUserIsPositionOwnerInShiva(alice, posId);
        assertGt(automatorBalanceAfter, automatorBalanceBefore, "Relayer should have received a fee");
    }

    /**
     * @notice Tests that a limit order (via build) reverts if the execution price is worse than the price limit
     *         due to market spread.
     */
    function testLimitBuildRevertsOnPriceLimitBreach() public {
        // 1. Alice signs a `build` message for a long position.
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);

        uint256 desiredPrice = currentPrice * 95 / 100;
        // Alice sets her priceLimit tightly to her desired price.
        uint256 priceLimit = desiredPrice;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, priceLimit, FIXED_NONCE, deadline, true, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 2. Price drops so the oracle price is exactly at the desired price.
        uint256 executionPrice = desiredPrice;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 3. Keeper attempts to execute.
        // The market's `ask` price will be `oracle_price + spread`, which is slightly
        // higher than `desiredPrice`. Since `priceLimit` is exactly `desiredPrice`,
        // the `build` call should revert with `price > limit`.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:slippage>max"); // Reverts from market because execution price > priceLimit
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a limit order (via build) reverts if the user has insufficient funds at execution time.
     */
    function testLimitBuildRevertsOnInsufficientFunds() public {
        // 1. Calculate the required amount and set Alice's balance to be just under it.
        uint256 notional = ONE.mulUp(5e18);
        uint256 tradingFeeRate = ovlMarket.params(uint256(Risk.Parameters.TradingFeeRate));
        uint256 tradingFee = notional.mulUp(tradingFeeRate);
        uint256 requiredAmount = ONE + tradingFee; // No relayer fee in this test

        // Deal slightly less than required
        deal(address(ovlToken), alice, requiredAmount - 1);
        approveToken(alice);

        // 2. Alice signs a `build` message for a long position.
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);

        uint256 priceLimit = currentPrice * 95 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, priceLimit, FIXED_NONCE, deadline, true, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops, making the order executable price-wise.
        uint256 executionPrice = priceLimit * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 4. Keeper attempts to execute, which should fail due to insufficient funds.
        // The revert comes from the OVL token contract's `transferFrom` function.
        vm.startPrank(automator);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a limit order cannot be replayed.
     */
    function testLimitBuildFailsOnReplayAttack() public {
        // 1. Define order parameters and simulate price drop to make it executable
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);
        uint256 priceLimit = currentPrice * 95 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        uint256 executionPrice = priceLimit * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 2. Alice signs the `build` message.
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, priceLimit, FIXED_NONCE, deadline, true, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Keeper executes the order successfully the first time.
        vm.startPrank(automator);
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );

        // 4. Keeper attempts to execute the same order again. It must fail.
        vm.expectRevert(IShiva.InvalidNonce.selector);
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a limit order fails if the nonce was cancelled.
     */
    function testLimitBuildFailsWithCancelledNonce() public {
        // 1. Define order parameters.
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);
        uint256 priceLimit = currentPrice * 95 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        // 2. Alice signs the `build` message.
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, priceLimit, FIXED_NONCE, deadline, true, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Alice cancels the nonce.
        vm.prank(alice);
        shiva.cancelNonce(FIXED_NONCE);

        // 4. Price drops to make the order executable.
        uint256 executionPrice = priceLimit * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 5. Keeper attempts to execute the order. It must fail.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidNonce.selector);
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a limit order fails when the contract is paused.
     */
    function testLimitBuildFailsWhenPaused() public {
        // 1. Define order parameters.
        uint256 priceLimit = 0; // Price doesn't matter for this test
        uint48 deadline = uint48(block.timestamp + 1 hours);

        // 2. Alice signs the `build` message.
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, priceLimit, FIXED_NONCE, deadline, true, BROKER_ID, type(uint256).max
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. The contract is paused.
        pauseShiva();

        // 4. Keeper attempts to execute the order. It must fail.
        vm.startPrank(automator);
        vm.expectRevert("Pausable: paused");
        limitOrderBuildOnBehalfOf(
            ONE, 5e18, priceLimit, deadline, true, signature, alice, type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a keeper-executed order reverts if the actual fee exceeds the max fee set by the user.
     */
    function testKeeperFeeExceedsMax() public {
        // 1. Set a high, predictable keeper fee via the oracle.
        uint256 actualKeeperFee = 10e18; // 10 OVL
        vm.startPrank(deployer);
        // Submit multiple times to ensure the micro-window average is updated
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(actualKeeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(actualKeeperFee / 1e10));
        vm.warp(block.timestamp + 60 * 60);
        keeperFeeAggregator.submit(keeperFeeAggregator.latestRound() + 1, int256(actualKeeperFee / 1e10));
        vm.stopPrank();

        // 2. Alice signs a limit order with a maxKeeperFee that is LOWER than the actual fee.
        uint256 maxKeeperFee = 5e18; // Alice is only willing to pay 5 OVL.
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, // collateral
            5e18, // leverage
            type(uint256).max, // priceLimit
            FIXED_NONCE,
            deadline,
            true, // isLong
            BROKER_ID,
            maxKeeperFee
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator attempts to execute the order.
        // The price conditions are met, but it should revert due to the fee mismatch.
        vm.startPrank(automator);
        vm.expectRevert(
            abi.encodeWithSelector(IShiva.KeeperFeeExceedsMax.selector, actualKeeperFee, maxKeeperFee)
        );
        limitOrderBuildOnBehalfOf(
            ONE,
            5e18,
            type(uint256).max,
            deadline,
            true,
            signature,
            alice,
            maxKeeperFee
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a limit order build with zero collateral is rejected.
     */
    function testZeroCollateralLimitOrderBuildFails() public {
        // 1. Alice signs a limit order with collateral set to 0.
        uint256 zeroCollateral = 0;
        uint256 leverage = 5e18;
        uint256 priceLimit = type(uint256).max;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            zeroCollateral,
            leverage,
            priceLimit,
            FIXED_NONCE,
            deadline,
            true, // isLong
            BROKER_ID,
            type(uint256).max // maxKeeperFee
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 2. Automator attempts to execute the order.
        // It should revert. The revert will likely come from the underlying OverlayV1Market
        // contract, which should not allow building a position with no collateral.
        vm.startPrank(automator);
        vm.expectRevert(abi.encodeWithSelector(0x5ce91fd0)); // StakeAmountIsZero error from RewardVault
        limitOrderBuildOnBehalfOf(
            zeroCollateral,
            leverage,
            priceLimit,
            deadline,
            true,
            signature,
            alice,
            type(uint256).max
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a stop-loss order with zero fraction is rejected.
     */
    function testStopLossWithZeroFractionFails() public {
        // 1. Alice builds a position.
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Alice signs a stop-loss order with fraction set to 0.
        uint256 zeroFraction = 0;
        uint256 triggerPrice = 100e18; // An arbitrary trigger price, doesn't matter for this test
        uint256 priceLimit = 99e18;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId,
            zeroFraction,
            triggerPrice,
            priceLimit,
            deadline,
            FIXED_NONCE,
            BROKER_ID,
            false, // payKeeperFee
            0 // maxKeeperFee
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price moves to make the stop-loss technically executable.
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator attempts to execute the order.
        // It should revert. The revert will likely come from the underlying OverlayV1Market
        // contract's unwind function, which should not allow unwinding zero fraction.
        vm.startPrank(automator);
        vm.expectRevert("OVLV1:fraction<min");
        stopLossOnBehalfOf(
            posId,
            zeroFraction,
            triggerPrice,
            priceLimit,
            deadline,
            signature,
            alice,
            false,
            0
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that a signature created on one chain cannot be used on a different chain.
     */
    function testSignatureWithDifferentChainIdFails() public {
        // 1. Alice builds a position.
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Set the chain ID to 1 (mainnet) and create a signature.
        vm.chainId(1);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId,
            ONE,
            triggerPrice,
            priceLimit,
            deadline,
            FIXED_NONCE,
            BROKER_ID,
            false,
            0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Change the chain ID to 4 (Rinkeby testnet).
        vm.chainId(4);

        // 4. Price moves to make the stop-loss technically executable.
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 5. Automator attempts to execute the order on the new chain.
        // It should fail with InvalidSignature because the signature was created for chainId 1,
        // but we're now on chainId 4.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(
            posId,
            ONE,
            triggerPrice,
            priceLimit,
            deadline,
            signature,
            alice,
            false,
            0
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that all order types fail when the market in the signature doesn't match the market in the call.
     */
    function testAllOrdersFailWithWrongMarketInSignature() public {
        // 1. Alice builds positions in both markets.
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true);
        
        // Create a position directly in otherOvlMarket
        uint256 priceLimitOther = Utils.getEstimatedPrice(ovlState, otherOvlMarket, ONE, 5e18, BASIC_SLIPPAGE, true);
        uint256 posId2 = shiva.build(
            ShivaStructs.Build(otherOvlMarket, BROKER_ID, true, ONE, 5e18, priceLimitOther)
        );
        vm.stopPrank();

        // 2. Create signatures for ovlMarket (the original market).
        uint48 deadline = uint48(block.timestamp + 3600);
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 99e18;

        // Stop-loss signature for ovlMarket
        bytes32 stopLossDigest = getStopLossOnBehalfOfDigest(
            posId1,
            ONE,
            triggerPrice,
            priceLimit,
            deadline,
            FIXED_NONCE,
            BROKER_ID,
            false,
            0
        );
        bytes memory stopLossSignature = getSignature(stopLossDigest, alicePk);

        // Take-profit signature for ovlMarket
        bytes32 takeProfitDigest = getTakeProfitOnBehalfOfDigest(
            posId1,
            ONE,
            priceLimit,
            FIXED_NONCE + 1,
            deadline,
            BROKER_ID,
            type(uint256).max
        );
        bytes memory takeProfitSignature = getSignature(takeProfitDigest, alicePk);

        // Limit order signature for ovlMarket
        bytes32 limitOrderDigest = getLimitOrderOnBehalfOfDigest(
            ONE,
            5e18,
            priceLimit,
            FIXED_NONCE + 2,
            deadline,
            true,
            BROKER_ID,
            type(uint256).max
        );
        bytes memory limitOrderSignature = getSignature(limitOrderDigest, alicePk);

        // 3. Price moves to make orders executable.
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Attempt to execute stop-loss with wrong market (otherOvlMarket).
        // Should fail with InvalidSignature because the signature was created for ovlMarket.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        shiva.stopLoss(
            ShivaStructs.StopLoss(
                otherOvlMarket, // Wrong market!
                BROKER_ID,
                false,
                posId2, // Use posId2 which exists in otherOvlMarket
                ONE,
                priceLimit,
                triggerPrice,
                0
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, stopLossSignature)
        );
        vm.stopPrank();

        // 5. Attempt to execute take-profit with wrong market.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        shiva.takeProfit(
            ShivaStructs.TakeProfit(
                otherOvlMarket, // Wrong market!
                BROKER_ID,
                posId2, // Use posId2 which exists in otherOvlMarket
                ONE,
                priceLimit,
                type(uint256).max
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE + 1, takeProfitSignature)
        );
        vm.stopPrank();

        // 6. Attempt to execute limit order with wrong market.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        shiva.limitOrderBuild(
            ShivaStructs.LimitOrder(
                otherOvlMarket, // Wrong market!
                BROKER_ID,
                true,
                ONE,
                5e18,
                priceLimit,
                type(uint256).max
            ),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE + 2, limitOrderSignature)
        );
        vm.stopPrank();
    }
} 