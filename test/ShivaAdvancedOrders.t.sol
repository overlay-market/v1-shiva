// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ShivaTestBase} from "./ShivaBase.t.sol";
import {IShiva} from "src/IShiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {IOverlayV1Feed} from "v1-core/contracts/interfaces/feeds/IOverlayV1Feed.sol";
import {Oracle} from "v1-core/contracts/libraries/Oracle.sol";

/**
 * @title ShivaAdvancedOrdersTest
 * @notice Test suite for advanced order types in the Shiva contract
 */
contract ShivaAdvancedOrdersTest is Test, ShivaTestBase {
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
} 