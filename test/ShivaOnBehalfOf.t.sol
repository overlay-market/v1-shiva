// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {Shiva} from "src/Shiva.sol";
import {Utils} from "src/utils/Utils.sol";
import {IShiva} from "src/IShiva.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";

import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";

/**
 * @title ShivaOnBehalfOfTest
 * @notice Test suite for the Shiva contract's on behalf of functionality
 * @dev This contract uses a forked network to test the Shiva contract
 * @dev The forked network is Bartio Berachain
 */
contract ShivaOnBehalfOfTest is Test, ShivaTestBase {
    using FixedPoint for uint256;

    /**
     * @notice Tests that building on behalf of fails due to unauthorized factory
     */
    function test_buildOnBehalfOf_unauthorizedFactory() public {
        removeAuthorizedFactory();

        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest =
            getBuildOnBehalfOfDigest(ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true);

        bytes memory signature = getSignature(digest, alicePk);

        vm.startPrank(automator);
        vm.expectRevert(IShiva.MarketNotValid.selector);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    /**
     * @notice Tests that the emergency withdraw method can be executed on behalf of another user
     */
    function test_emergencyWithdraw_onBehalfOf() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        shutDownMarket();

        vm.startPrank(automator);
        shiva.emergencyWithdraw(ovlMarket, posId, alice);

        assertFractionRemainingIsZero(address(shiva), posId);
    }

    /**
     * @notice Tests that a position can be built on behalf of another user
     */
    function test_buildOnBehalfOf_ownership() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest =
            getBuildOnBehalfOfDigest(ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true);

        bytes memory signature = getSignature(digest, alicePk);

        // execute `buildOnBehalfOf` with `automator`
        vm.prank(automator);
        uint256 posId =
            buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);

        assertFractionRemainingIsZero(alice, posId);
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    /**
     * @notice Tests that building on behalf of fails due to an expired deadline
     */
    function test_buildOnBehalfOf_expiredDeadline() public {
        uint48 deadline = uint48(block.timestamp - 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest =
            getBuildOnBehalfOfDigest(ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true);

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        vm.prank(automator);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    /**
     * @notice Tests that building on behalf of fails due to an invalid signature (bad nonce)
     */
    function test_buildOnBehalfOf_invalidSignature_badNonce() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        // nonce is incremented by 1 to make the signature invalid
        bytes32 digest =
            getBuildOnBehalfOfDigest(ONE, ONE, priceLimit, shiva.nonces(alice) + 1, deadline, true);

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    /**
     * @notice Tests that building on behalf of fails due to an invalid signature (bad owner)
     */
    function test_buildOnBehalfOf_invalidSignature_badOwner() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest =
            getBuildOnBehalfOfDigest(ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true);

        // sign the message as Bob instead of Alice
        bytes memory signature = getSignature(digest, bobPk);

        // the position is attempted to be built on behalf of Alice
        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    /**
     * @notice Tests that building on behalf of fails due to a paused Shiva contract
     */
    function test_buildOnBehalfOf_pausedShiva() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest =
            getBuildOnBehalfOfDigest(ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true);

        bytes memory signature = getSignature(digest, alicePk);

        pauseShiva();

        vm.prank(automator);
        vm.expectRevert("Pausable: paused");
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    /**
     * @notice Tests that a position can be unwound on behalf of another user
     */
    function test_unwindOnBehalfOf_withdrawal() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest =
            getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, shiva.nonces(alice), deadline);

        bytes memory signature = getSignature(digest, alicePk);

        // execute `unwindOnBehalfOf` with `automator`
        vm.prank(automator);
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);

        assertFractionRemainingIsZero(address(shiva), posId);
    }

    /**
     * @notice Tests that unwinding on behalf of fails due to an expired deadline
     */
    function test_unwindOnBehalfOf_expiredDeadline() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp - 1 hours);
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest =
            getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, shiva.nonces(alice), deadline);

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        vm.prank(automator);
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);
    }

    /**
     * @notice Tests that unwinding on behalf of fails due to an invalid signature (bad nonce)
     */
    function test_unwindOnBehalfOf_invalidSignature_badNonce() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest =
            getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, shiva.nonces(alice) + 1, deadline);

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);
    }

    /**
     * @notice Tests that unwinding on behalf of fails due to an invalid signature (bad owner)
     */
    function test_unwindOnBehalfOf_invalidSignature_badOwner() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest =
            getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, shiva.nonces(alice), deadline);

        // sign the message as Bob instead of Alice
        bytes memory signature = getSignature(digest, bobPk);

        // the position is attempted to be unwound on behalf of Alice
        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);
    }

    /**
     * @notice Tests that unwinding on behalf of fails due to a paused Shiva contract
     */
    function test_unwindOnBehalfOf_pausedShiva() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest =
            getUnwindOnBehalfOfDigest(posId, ONE, priceLimit, shiva.nonces(alice), deadline);

        bytes memory signature = getSignature(digest, alicePk);

        pauseShiva();

        vm.prank(automator);
        vm.expectRevert("Pausable: paused");
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);
    }

    /**
     * @notice Tests that a single position can be built on behalf of another user
     */
    function test_buildSingleOnBehalfOf_ownership() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest =
            getBuildSingleOnBehalfOfDigest(ONE, ONE, posId1, shiva.nonces(alice), deadline);

        bytes memory signature = getSignature(digest, alicePk);

        uint256 unwindPriceLimit =
            Utils.getUnwindPrice(ovlState, ovlMarket, posId1, address(shiva), ONE, BASIC_SLIPPAGE);
        uint256 buildPriceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        // execute `buildSingleOnBehalfOf` with `automator`
        vm.prank(automator);
        uint256 posId2 = buildSinglePositionOnBehalfOf(
            ONE, ONE, posId1, unwindPriceLimit, buildPriceLimit, deadline, signature, alice
        );

        // the first position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId1);
        // the second position is associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId2);
        // the second position is not associated with Alice in the ovlMarket
        assertFractionRemainingIsZero(alice, posId2);
        // the second position is associated with Shiva in the ovlMarket
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId2);
        // shiva has no tokens after the transaction
        assertOVLTokenBalanceIsZero(address(shiva));
    }

    /**
     * @notice Tests that building a single position on behalf of fails due to an expired deadline
     */
    function test_buildSingleOnBehalfOf_expiredDeadline() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp - 1 hours);

        bytes32 digest =
            getBuildSingleOnBehalfOfDigest(ONE, ONE, posId1, shiva.nonces(alice), deadline);

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        vm.prank(automator);
        buildSinglePositionOnBehalfOf(ONE, ONE, posId1, ONE, ONE, deadline, signature, alice);
    }

    /**
     * @notice Tests that building a single position on behalf of fails due to an invalid signature (bad nonce)
     */
    function test_buildSingleOnBehalfOf_invalidSignature_badNonce() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest =
            getBuildSingleOnBehalfOfDigest(ONE, ONE, posId1, shiva.nonces(alice) + 1, deadline);

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildSinglePositionOnBehalfOf(ONE, ONE, posId1, ONE, ONE, deadline, signature, alice);
    }

    /**
     * @notice Tests that building a single position on behalf of fails due to an invalid signature (bad owner)
     */
    function test_buildSingleOnBehalfOf_invalidSignature_badOwner() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest =
            getBuildSingleOnBehalfOfDigest(ONE, ONE, posId1, shiva.nonces(alice), deadline);

        // sign the message as Bob
        bytes memory signature = getSignature(digest, bobPk);

        // the position is attempted to be built on behalf of Alice
        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildSinglePositionOnBehalfOf(ONE, ONE, posId1, ONE, ONE, deadline, signature, alice);
    }

    /**
     * @notice Tests that building a single position on behalf of fails due to a paused Shiva contract
     */
    function test_buildSingleOnBehalfOf_pausedShiva() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest =
            getBuildSingleOnBehalfOfDigest(ONE, ONE, posId1, shiva.nonces(alice), deadline);

        bytes memory signature = getSignature(digest, alicePk);

        pauseShiva();

        vm.prank(automator);
        vm.expectRevert("Pausable: paused");
        buildSinglePositionOnBehalfOf(ONE, ONE, posId1, ONE, ONE, deadline, signature, alice);
    }
}
