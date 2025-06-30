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

    /**
     * @dev Sets up the initial state for the test contract
     */
    function setUp() public override {
        super.setUp();
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
            BROKER_ID
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
            false // payRelayerFee
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
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before trigger, should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true);
        vm.stopPrank();

        // 4. Price drops, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 999 / 1000; // Price drops just below the trigger
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60); // Advance time to ensure oracle update

        // 5. Automator executes the stop-loss order successfully and gets paid
        vm.startPrank(automator);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true);
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
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before trigger, should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
        vm.stopPrank();

        // 4. Price rises, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 1001 / 1000; // Price rises just above the trigger
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60); // Advance time

        // 5. Automator executes the stop-loss order successfully (no fee)
        vm.startPrank(automator);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        vm.startPrank(automator);

        // 3. Try to execute with different parameters, all should revert with InvalidSignature
        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(otherPosId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE / 2, triggerPrice, priceLimit, deadline, signature, alice, false);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice + 1, priceLimit, deadline, signature, alice, false);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit + 1, deadline, signature, alice, false);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline + 1, signature, alice, false);

        // Different brokerId
        vm.expectRevert(IShiva.InvalidSignature.selector);
        shiva.stopLoss(
            ShivaStructs.StopLoss(ovlMarket, BROKER_ID + 1, posId, ONE, triggerPrice, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false
        );

        // Different market - this reverts with NotPositionOwner because the check happens before the signature validation
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        shiva.stopLoss(
            ShivaStructs.StopLoss(otherOvlMarket, BROKER_ID, posId, ONE, triggerPrice, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);

        // 3. Bob signs the digest instead of Alice
        bytes memory signature = getSignature(digest, bobPk);

        // 4. Automator tries to execute on behalf of Alice with Bob's signature, which should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE + 1, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute. The call inside `stopLossOnBehalfOf` uses `FIXED_NONCE`,
        // so the signature won't match.
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidSignature.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the stop-loss order successfully
        vm.startPrank(automator);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);

        // 5. Automator tries to execute the same order again, should fail due to used nonce
        vm.expectRevert(IShiva.InvalidNonce.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Alice cancels the nonce used in the signature
        vm.prank(alice);
        shiva.cancelNonce(FIXED_NONCE);

        // 4. Automator tries to execute, it should fail
        vm.startPrank(automator);
        vm.expectRevert(IShiva.InvalidNonce.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. The contract is paused
        pauseShiva();

        // 4. Automator tries to execute, it should fail
        vm.startPrank(automator);
        vm.expectRevert("Pausable: paused");
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, bobPk);

        // 3. Automator tries to execute on behalf of Bob for Alice's position, should fail ownership check
        vm.startPrank(automator);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, bob, false);
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
            posId, fractionToUnwind, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 999 / 1000;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the partial stop-loss
        vm.startPrank(automator);
        stopLossOnBehalfOf(posId, fractionToUnwind, triggerPrice, priceLimit, deadline, signature, alice, false);
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
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, true); // 1 OVL collateral, 5x leverage
        vm.stopPrank();

        // 2. Alice signs a stop-loss order with a trigger and a price limit
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100; // 5% price drop
        uint256 priceLimit = triggerPrice * 99 / 100; // 1% slippage tolerance for the unwind
        uint48 deadline = uint48(block.timestamp + 3600); // 1 hour deadline

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops significantly, below both the trigger price and the price limit
        uint256 executionPrice = priceLimit * 95 / 100; // Price drops 5% below the user's limit
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60); // Advance time to ensure oracle update

        // 4. Automator attempts to execute the stop-loss order
        // It should fail because the current price is worse than the user's priceLimit.
        // The exact revert message comes from the OverlayV1Market contract.
        vm.startPrank(automator);
        vm.expectRevert();
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
        vm.stopPrank();

        // 5. Verify position is NOT closed
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0, "Position should not have been closed");
    }

    /**
     * @notice Tests that stop loss reverts with InsufficientUnwindAmountForFee if the
     *         unwound value is less than the relayer fee.
     */
    function testStopLossFailsWithInsufficientFundsForFee() public {
        // 1. Alice builds a long position with small collateral and lower leverage
        vm.startPrank(alice);
        uint256 collateral = 0.5e18;
        // Lower leverage to avoid liquidation on price drop
        uint256 posId = buildPosition(collateral, 2e18, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // 2. Set a relayer fee that is greater than the expected unwind amount
        vm.startPrank(deployer);
        uint256 highRelayerFee = 0.6e18;
        shiva.setRelayerFee(highRelayerFee);
        vm.stopPrank();

        // 3. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0);

        // A smaller price drop to avoid hitting liquidation
        uint256 triggerPrice = currentPrice * 98 / 100; // 2% price drop
        uint256 priceLimit = triggerPrice * 90 / 100; // 10% slippage to ensure it passes price limit check
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 4. Price drops, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 98 / 100; // Price drops just below trigger
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 5. Automator executes the stop-loss, expecting it to fail because the unwind amount
        // will be less than the collateral, which is less than the required fee.
        vm.startPrank(automator);
        vm.expectRevert();
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true); // payRelayerFee = true
        vm.stopPrank();
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
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
        vm.expectRevert(); // Reverts from market with "OVLV1:!pos"
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. The market is shut down
        shutDownMarket();

        // 4. Price drops, which would normally make the stop-loss executable
        aggregator.submit(aggregator.latestRound() + 1, int256(triggerPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 5. Automator attempts to execute the stop-loss, which should fail
        // because the market is shut down.
        vm.startPrank(automator);
        vm.expectRevert(); // Reverts from market with "OVLV1:shutdown"
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
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
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price drops to be exactly the trigger price
        aggregator.submit(aggregator.latestRound() + 1, int256(triggerPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the stop-loss order successfully
        vm.startPrank(automator);
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
        vm.stopPrank();

        // 5. Verify position is closed
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    /**
     * @notice Tests that a stop loss order for a short position reverts if the execution price is worse than the price limit.
     */
    function testStopLossRevertsIfPriceLimitBreachedShort() public {
        // 1. Alice builds a short position
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, 5e18, BASIC_SLIPPAGE, false); // 1 OVL collateral, 5x leverage, short
        vm.stopPrank();

        // 2. Alice signs a stop-loss order with a trigger and a price limit
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);

        uint256 triggerPrice = currentPrice * 105 / 100; // 5% price rise
        uint256 priceLimit = triggerPrice * 101 / 100; // 1% slippage tolerance (higher is worse for shorts)
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest = getStopLossOnBehalfOfDigest(
            posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price rises significantly, above both the trigger price and the price limit
        uint256 executionPrice = priceLimit * 105 / 100; // Price jumps 5% beyond the user's limit
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator attempts to execute the stop-loss order
        // It should fail because the current price is worse (higher) than the user's priceLimit.
        vm.startPrank(automator);
        vm.expectRevert(); // Reverts from market with "OVLV1:price>limit"
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, false);
        vm.stopPrank();

        // 5. Verify position is NOT closed
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0, "Position should not have been closed");
    }

    /**
     * @notice Tests that stop loss for a short position reverts with InsufficientUnwindAmountForFee
     *         if the unwound value is less than the relayer fee.
     */
    function testStopLossFailsWithInsufficientFundsForFeeShort() public {
        // 1. Alice builds a short position with small collateral and lower leverage
        vm.startPrank(alice);
        uint256 collateral = 0.5e18;
        uint256 posId = buildPosition(collateral, 2e18, BASIC_SLIPPAGE, false); // Lower leverage
        vm.stopPrank();

        // 2. Set a relayer fee that is greater than the expected unwind amount
        vm.startPrank(deployer);
        uint256 highRelayerFee = 0.6e18;
        shiva.setRelayerFee(highRelayerFee);
        vm.stopPrank();

        // 3. Alice signs a stop-loss order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);

        // A smaller price rise to avoid hitting liquidation
        uint256 triggerPrice = currentPrice * 102 / 100; // 2% price rise
        uint256 priceLimit = triggerPrice * 110 / 100; // 10% slippage to ensure it passes price limit check
        uint48 deadline = uint48(block.timestamp + 3600);

        bytes32 digest =
            getStopLossOnBehalfOfDigest(posId, ONE, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 4. Price rises, making the stop-loss executable
        uint256 executionPrice = triggerPrice * 101 / 100; // Price rises just above trigger
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 5. Automator executes the stop-loss, expecting it to fail because the unwind amount
        // will be less than the collateral, which is less than the required fee.
        vm.startPrank(automator);
        vm.expectRevert(); // Expect InsufficientUnwindAmountForFee
        stopLossOnBehalfOf(posId, ONE, triggerPrice, priceLimit, deadline, signature, alice, true); // payRelayerFee = true
        vm.stopPrank();
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

        bytes32 digest = getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before price target is met. Should fail.
        // The market will revert because the current execution price is less than the priceLimit.
        vm.startPrank(automator);
        vm.expectRevert(); // OVLV1:price<limit
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            true
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

        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            true // payRelayerFee = true
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

        bytes32 digest = getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Automator tries to execute before price target is met. Should fail.
        // The market will revert because the current execution price is greater than the priceLimit.
        vm.startPrank(automator);
        vm.expectRevert(); // OVLV1:price>limit
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false
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

        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false // payRelayerFee = false
        );

        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        uint256 automatorBalanceAfter = ovlToken.balanceOf(automator);
        vm.stopPrank();

        // 6. Verify position is closed and balances are correct
        assertFractionRemainingIsZero(address(shiva), posId);
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received her profits");
        assertEq(automatorBalanceAfter, automatorBalanceBefore, "Relayer should not have received a fee");
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

        bytes32 digest = getUnwindOnBehalfOfDigest(posId, fractionToUnwind, priceLimit, FIXED_NONCE, deadline, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price rises, making the take-profit executable
        uint256 executionPrice = priceLimit * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the partial take-profit
        vm.startPrank(automator);
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, fractionToUnwind, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false
        );
        vm.stopPrank();

        // 5. Verify position is partially closed (approximately 50% remaining)
        (,,,,,,, uint16 fractionRemaining) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertApproxEqAbs(fractionRemaining, 5000, 10); // 5000 is 50% in basis points
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

        bytes32 digest = getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID);
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
        vm.expectRevert(); // Reverts from market with "OVLV1:!pos"
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false
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

        bytes32 digest = getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, FIXED_NONCE, deadline, BROKER_ID);
        bytes memory signature = getSignature(digest, alicePk);

        // 3. Price rises, making the take-profit executable
        uint256 executionPrice = priceLimit * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 60 * 60);

        // 4. Automator executes the order successfully
        vm.startPrank(automator);
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false
        );

        // 5. Automator tries to execute the same order again, should fail due to used nonce
        vm.expectRevert(IShiva.InvalidNonce.selector);
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, BROKER_ID, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, deadline, FIXED_NONCE, signature),
            false
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
    //                       LIMIT ORDER TESTS
    //
    // =================================================================

    /**
     * @notice Tests that a limit order for a long position executes when the price drops.
     */
    function testLimitOrderLongExecutes() public {
        // 1. Define order parameters and sign the limit order
        // Get the current market price to set a realistic trigger price
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0); // Use ask price for buying (long)

        // Set a trigger price 5% below the current market price
        uint256 triggerPrice = currentPrice * 95 / 100;

        // Set a price limit for the build execution (slippage control).
        // Allow 1% slippage from the trigger price.
        uint256 priceLimit = triggerPrice * 101 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        // Alice signs the message for the limit order
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, // collateral
            5e18, // leverage
            true, // isLong
            triggerPrice,
            priceLimit,
            deadline,
            FIXED_NONCE,
            BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Structure the parameters for the function call
        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        // 2. Automator attempts to execute before the trigger condition is met
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false); // No relayer fee for this test
        vm.stopPrank();

        // 3. Simulate a price drop to make the limit order executable
        // We set the new price to be slightly below the trigger price to ensure the condition is met
        uint256 executionPrice = triggerPrice * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours); // Advance time to ensure oracle TWAP reflects the new price

        // 4. Automator executes the limit order successfully
        vm.startPrank(automator);
        uint256 posId = limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        vm.stopPrank();

        // 5. Verify the position has been created successfully
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        assertUserIsPositionOwnerInShiva(alice, posId);

        // Verify the position is long
        (,,,, bool isLongAfter,,,) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertTrue(isLongAfter, "Position should be long");
    }

    /**
     * @notice Tests that a limit order for a short position executes when the price rises, and the relayer gets paid.
     */
    function testLimitOrderShortExecutesWithFee() public {
        // 1. Define order parameters and sign the limit order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.bid(data, 0); // Use bid price for selling (short)

        // Set a trigger price 5% above the current market price
        uint256 triggerPrice = currentPrice * 105 / 100;

        // Set a price limit for the build execution (slippage control).
        // For a short, the execution price must be >= priceLimit.
        uint256 priceLimit = triggerPrice * 99 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, false, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: false,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        // 2. Automator attempts to execute before the trigger condition is met
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, true); // Pay relayer fee
        vm.stopPrank();

        // 3. Simulate a price rise to make the limit order executable
        uint256 executionPrice = triggerPrice * 101 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 4. Automator executes the limit order successfully and gets paid
        vm.startPrank(automator);
        uint256 automatorBalanceBefore = ovlToken.balanceOf(automator);
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);

        uint256 posId = limitOrderOnBehalfOf(params, signature, alice, deadline, true);

        uint256 automatorBalanceAfter = ovlToken.balanceOf(automator);
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        vm.stopPrank();

        // 5. Verify position is created and is short
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        assertUserIsPositionOwnerInShiva(alice, posId);
        (,,,, bool isLongAfter,,,) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertFalse(isLongAfter, "Position should be short");

        // 6. Verify relayer received a fee
        assertGt(automatorBalanceAfter, automatorBalanceBefore, "Relayer should have received a fee");
        assertEq(automatorBalanceAfter - automatorBalanceBefore, shiva.relayerFee(), "Relayer fee is incorrect");

        // 7. Verify Alice's balance was reduced by collateral + trading fee + relayer fee
        uint256 notional = ONE.mulUp(5e18);
        uint256 tradingFeeRate = ovlMarket.params(uint256(Risk.Parameters.TradingFeeRate));
        uint256 tradingFee = notional.mulUp(tradingFeeRate);
        uint256 expectedAliceBalance = aliceBalanceBefore - (ONE + tradingFee + shiva.relayerFee());
        assertEq(aliceBalanceAfter, expectedAliceBalance, "Alice's balance is incorrect after short limit order");
    }

    /**
     * @notice Tests that limit order reverts if the trigger condition is not met.
     */
    function testLimitOrderRevertsWhenTriggerNotMet() public {
        // 1. Sign a limit order for a long position
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);
        uint256 triggerPrice = currentPrice * 95 / 100; // Trigger if price drops 5%
        uint256 priceLimit = triggerPrice * 101 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        // 2. Automator attempts to execute without price change, expecting revert
        vm.startPrank(automator);
        vm.expectRevert(IShiva.TriggerNotMet.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        vm.stopPrank();
    }

    /**
     * @notice Tests that limit order reverts if the deadline has expired.
     */
    function testLimitOrderRevertsOnExpiredDeadline() public {
        // 1. Sign a limit order with a deadline in the past
        uint256 triggerPrice = 1e18;
        uint256 priceLimit = 1e18;
        uint48 deadline = uint48(block.timestamp - 1); // Deadline has already passed

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        // 2. Automator attempts to execute, expecting revert due to expired deadline
        vm.startPrank(automator);
        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        vm.stopPrank();
    }

    /**
     * @notice Tests that limit order reverts due to various invalid signature scenarios.
     */
    function testLimitOrderRevertsOnInvalidSignature() public {
        // 1. Set up and sign a valid limit order for Alice
        uint256 triggerPrice = 100e18;
        uint256 priceLimit = 101e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        // --- Scenario A: Mismatched Parameters ---
        // Create a base params struct that matches the signature
        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        vm.startPrank(automator);

        // Test with wrong collateral
        params.collateral = ONE + 1;
        vm.expectRevert(IShiva.InvalidSignature.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        params.collateral = ONE; // Reset for next test

        // Test with wrong leverage
        params.leverage = 4e18;
        vm.expectRevert(IShiva.InvalidSignature.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        params.leverage = 5e18; // Reset

        // Test with wrong isLong
        params.isLong = false;
        vm.expectRevert(IShiva.InvalidSignature.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        params.isLong = true; // Reset

        // --- Scenario B: Wrong Signer ---
        // Create a signature from Bob for Alice's order parameters
        bytes memory bobSignature = getSignature(digest, bobPk);

        // Attempt to execute for Alice with Bob's signature
        vm.expectRevert(IShiva.InvalidSignature.selector);
        limitOrderOnBehalfOf(params, bobSignature, alice, deadline, false);

        // --- Scenario C: Mismatched Nonce ---
        // Sign with a different nonce
        bytes32 wrongNonceDigest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE + 1, BROKER_ID
        );
        bytes memory wrongNonceSignature = getSignature(wrongNonceDigest, alicePk);
        // Execute with the original nonce, causing a mismatch
        vm.expectRevert(IShiva.InvalidSignature.selector);
        limitOrderOnBehalfOf(params, wrongNonceSignature, alice, deadline, false);

        vm.stopPrank();
    }

    /**
     * @notice Tests that limit order reverts if the nonce has been used or cancelled.
     */
    function testLimitOrderRevertsOnUsedOrCancelledNonce() public {
        // --- Scenario A: Used Nonce ---
        // 1. Successfully execute a limit order
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);
        uint256 triggerPrice = currentPrice * 95 / 100;
        uint256 priceLimit = triggerPrice * 101 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        uint256 executionPrice = triggerPrice * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        vm.startPrank(automator);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);

        // 2. Attempt to execute it again, expecting InvalidNonce revert
        vm.expectRevert(IShiva.InvalidNonce.selector);
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        vm.stopPrank();

        // --- Scenario B: Cancelled Nonce ---
        // 1. Alice signs a new order with a new nonce
        uint256 newNonce = FIXED_NONCE + 1;
        bytes32 newDigest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, newNonce, BROKER_ID
        );
        bytes memory newSignature = getSignature(newDigest, alicePk);

        // 2. Alice cancels the new nonce before execution
        vm.prank(alice);
        shiva.cancelNonce(newNonce);

        // 3. Automator attempts to execute, expecting InvalidNonce revert
        vm.startPrank(automator);
        // We need to use a custom call to pass the new nonce
        vm.expectRevert(IShiva.InvalidNonce.selector);
        shiva.limitOrder(
            params,
            ShivaStructs.OnBehalfOf(alice, deadline, newNonce, newSignature),
            false
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that limit order reverts when the contract is paused.
     */
    function testLimitOrderRevertsWhenPaused() public {
        // 1. Sign a limit order
        uint256 triggerPrice = 1e18;
        uint256 priceLimit = 1e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);
        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        // 2. Pause the contract
        pauseShiva();

        // 3. Attempt to execute, expecting Pausable: paused revert
        vm.startPrank(automator);
        vm.expectRevert("Pausable: paused");
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        vm.stopPrank();
    }

    /**
     * @notice Tests that a limit order reverts if the execution price is worse than the price limit.
     */
    function testLimitOrderRevertsOnPriceLimitBreach() public {
        // 1. Alice signs a limit order for a long position
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100; // Trigger at 5% drop

        // Set a price limit that is slightly lower than the trigger price.
        // This simulates a scenario where the price drops to the trigger level,
        // but the market's execution price (due to spread) is worse than the user's limit.
        uint256 priceLimit = triggerPrice * 999 / 1000; // 0.1% tighter than trigger
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        // 2. Price drops exactly to the trigger price. The trigger condition is met.
        uint256 executionPrice = triggerPrice;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 3. Automator attempts to execute.
        // The trigger condition `ask <= triggerPrice` is met.
        // However, during the build, the execution `ask` price from the market
        // will be `oracle_price + spread`, which will be `triggerPrice + spread`.
        // Since `priceLimit` is lower than `triggerPrice`, the `build` call should
        // revert with `price > limit`.
        vm.startPrank(automator);
        vm.expectRevert(); // Reverts from market with "OVLV1:price>limit"
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        vm.stopPrank();
    }

    /**
     * @notice Tests that a limit order reverts if the user has insufficient funds at execution time.
     */
    function testLimitOrderRevertsOnInsufficientFunds() public {
        // 1. Calculate the required amount and set Alice's balance to be just under it.
        uint256 notional = ONE.mulUp(5e18);
        uint256 tradingFeeRate = ovlMarket.params(uint256(Risk.Parameters.TradingFeeRate));
        uint256 tradingFee = notional.mulUp(tradingFeeRate);
        uint256 requiredAmount = ONE + tradingFee; // No relayer fee in this test

        // Deal slightly less than required
        deal(address(ovlToken), alice, requiredAmount - 1);
        approveToken(alice);

        // 2. Alice signs a limit order for a long position
        IOverlayV1Feed feed = IOverlayV1Feed(ovlMarket.feed());
        Oracle.Data memory data = feed.latest();
        uint256 currentPrice = ovlMarket.ask(data, 0);

        uint256 triggerPrice = currentPrice * 95 / 100;
        uint256 priceLimit = triggerPrice * 101 / 100;
        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getLimitOrderOnBehalfOfDigest(
            ONE, 5e18, true, triggerPrice, priceLimit, deadline, FIXED_NONCE, BROKER_ID
        );
        bytes memory signature = getSignature(digest, alicePk);

        ShivaStructs.LimitOrder memory params = ShivaStructs.LimitOrder({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            collateral: ONE,
            leverage: 5e18,
            triggerPrice: triggerPrice,
            priceLimit: priceLimit
        });

        // 3. Price drops, making the limit order executable
        uint256 executionPrice = triggerPrice * 99 / 100;
        aggregator.submit(aggregator.latestRound() + 1, int256(executionPrice / 1e10));
        vm.warp(block.timestamp + 1 hours);

        // 4. Automator attempts to execute, which should fail due to insufficient funds.
        // The revert comes from the OVL token contract's `transferFrom` function.
        vm.startPrank(automator);
        vm.expectRevert();
        limitOrderOnBehalfOf(params, signature, alice, deadline, false);
        vm.stopPrank();
    }
} 