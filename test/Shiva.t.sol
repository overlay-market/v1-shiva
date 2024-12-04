// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Shiva} from "src/Shiva.sol";
import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1Factory} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {Constants} from "./utils/Constants.sol";
import {Utils} from "src/utils/Utils.sol";
import {OverlayV1Factory} from "v1-periphery/lib/v1-core/contracts/OverlayV1Factory.sol";
import {OverlayV1Token} from "v1-periphery/lib/v1-core/contracts/OverlayV1Token.sol";
import {Risk} from "v1-periphery/lib/v1-core/contracts/libraries/Risk.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {IShiva} from "src/IShiva.sol";

contract ShivaTest is Test, ShivaTestBase {

    // Test setup
    // Governor adds an authorized factory
    function test_addAuthorizedFactory() public {
        addAuthorizedFactory();
    }

    // Governor removes an authorized factory
    function test_removeAuthorizedFactory() public {
        removeAuthorizedFactory();
    }

    // Build should fail due to unauthorized factory
    function test_build_unauthorizedFactory() public {
        // Governor removes the authorized factory; this is already added in the setup
        removeAuthorizedFactory();

        vm.startPrank(alice);
        vm.expectRevert(IShiva.MarketNotValid.selector);
        shiva.build(ShivaStructs.Build(ovMarket, true, ONE, ONE, BASIC_SLIPPAGE));
    }

    // Build on behalf of should fail due to unauthorized factory
    function test_buildOnBehalfOf_unauthorizedFactory() public {
        // Governor removes the authorized factory; this is already added in the setup
        removeAuthorizedFactory();

        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest = getBuildOnBehalfOfDigest(
            ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true
        );

        // sign the message as Alice
        bytes memory signature = getSignature(digest, alicePk);

        vm.startPrank(automator);
        vm.expectRevert(IShiva.MarketNotValid.selector);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    // Add authorized factory fail not governor
    function test_addAuthorizedFactory_notGovernor() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shiva.addFactory(IOverlayV1Factory(address(0)));
    }

    // Remove authorized factory fail not governor
    function test_removeAuthorizedFactory_notGovernor() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shiva.removeFactory(IOverlayV1Factory(address(0)));
    }

    // Build method tests

    // Alice builds a position through Shiva
    function test_build() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // the position is not associated with Alice in the ovMarket
        assertFractionRemainingIsZero(alice, posId);
        // the position is associated with Shiva in the ovMarket
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        // the position is associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    // Alice and Bob build positions, after each build, Shiva should not have OVL tokens
    function test_build_noOVL() public {
        uint256 numberWithDecimals = 1234567890123456789;
        vm.startPrank(alice);
        buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);
        assertOVTokenBalanceIsZero(address(shiva));
        vm.stopPrank();

        vm.startPrank(bob);
        buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);
        assertOVTokenBalanceIsZero(address(shiva));
        vm.stopPrank();
    }

    // Build leverage less than minimum
    function test_build_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert("Shiva:lev<min");
        shiva.build(ShivaStructs.Build(ovMarket, true, ONE, ONE - 1, priceLimit));
    }

    // Build fail not enough allowance
    function test_build_notEnoughAllowance() public {
        deal(address(ovToken), charlie, 1000e18);
        vm.startPrank(charlie);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(ShivaStructs.Build(ovMarket, true, ONE, ONE, priceLimit));
    }

    // Build fail enough allowance but not enough balance considering the trading fee
    function test_build_notEnoughBalance() public {
        deal(address(ovToken), charlie, ONE);
        vm.startPrank(charlie);
        ovToken.approve(address(shiva), type(uint256).max);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(ShivaStructs.Build(ovMarket, true, ONE, ONE, priceLimit));
    }

    // Unwind method tests

    // Alice builds a position and then unwinds it through Shiva
    function test_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, ONE, BASIC_SLIPPAGE);

        // the position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    function test_partial_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // Alice unwinds 50% of her position through Shiva
        unwindPosition(posId, 5e17, BASIC_SLIPPAGE);

        // the position is successfully unwound
        assertFractionRemaining(address(shiva), posId, 5000);
        // The position is still associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    function test_unwind_notOwner(
        bool isLong
    ) public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, isLong);
        vm.stopPrank();
        // Bob tries to unwind Alice's position through Shiva
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, !isLong);
        vm.startPrank(bob);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        shiva.unwind(ShivaStructs.Unwind(ovMarket, posId, ONE, priceLimit));
    }

    // Emergency withdraw method tests

    // Alice builds a position and then emergency withdraws it through Shiva
    function test_emergencyWithdraw() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        shutDownMarket();

        // Alice emergency withdraws her position through Shiva
        vm.prank(alice);
        shiva.emergencyWithdraw(ovMarket, posId, alice);

        // the position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    function test_emergencyWithdraw_notOwner() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();
        // Bob tries to emergency withdraw Alice's position through Shiva
        shutDownMarket();
        vm.startPrank(bob);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        shiva.emergencyWithdraw(ovMarket, posId, bob);
    }

    // Automator can execute the emergency withdraw method on behalf of Alice
    function test_emergencyWithdraw_onBehalfOf() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        shutDownMarket();

        vm.startPrank(automator);
        shiva.emergencyWithdraw(ovMarket, posId, alice);

        // the position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    // BuildSingle method tests

    // Alice builds a position through Shiva and then builds another one
    function test_buildSingle() public {
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        assertOVTokenBalanceIsZero(address(shiva));

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        uint256 posId2 = buildSinglePosition(ONE, ONE, posId1, BASIC_SLIPPAGE);

        // the first position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId1);
        // the second position is associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId2);
        // the second position is not associated with Alice in the ovMarket
        assertFractionRemainingIsZero(alice, posId2);
        // the second position is not associated with Shiva in the ovMarket
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId2);
        // shiva has no tokens after the transaction
        assertOVTokenBalanceIsZero(address(shiva));
    }

    // Alice builds a position through Shiva and then builds another one
    function testFuzz_buildSingle(uint256 collateral, uint256 leverage) public {
        collateral =
            bound(collateral, ovMarket.params(uint256(Risk.Parameters.MinCollateral)), 500e18);
        leverage = bound(leverage, ONE, ovMarket.params(uint256(Risk.Parameters.CapLeverage)));

        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        assertOVTokenBalanceIsZero(address(shiva));

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        uint256 posId2 = buildSinglePosition(collateral, leverage, posId1, BASIC_SLIPPAGE);

        // the first position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId1);
        // the second position is associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId2);
        // the second position is not associated with Alice in the ovMarket
        assertFractionRemainingIsZero(alice, posId2);
        // the second position is not associated with Shiva in the ovMarket
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId2);
        // shiva has no tokens after the transaction
        assertOVTokenBalanceIsZero(address(shiva));
    }

    // Alice and Bob build positions, after each build, Shiva should not have OVL tokens
    function test_buildSingle_noOVL() public {
        uint256 numberWithDecimals = 1234567890123456789;
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        buildSinglePosition(numberWithDecimals, numberWithDecimals, posId1, BASIC_SLIPPAGE);
        assertOVTokenBalanceIsZero(address(shiva));

        vm.startPrank(bob);
        uint256 posId3 = buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);

        // Bob builds a second position after a while
        vm.warp(block.timestamp + 1000);

        buildSinglePosition(numberWithDecimals, numberWithDecimals, posId3, BASIC_SLIPPAGE);
        assertOVTokenBalanceIsZero(address(shiva));
    }

    // BuildSingle fail previous position not owned by the caller
    function test_buildSingle_noPreviousPosition() public {
        vm.startPrank(alice);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        buildSinglePosition(ONE, ONE, 0, BASIC_SLIPPAGE);
    }

    // BuildSingle fail leverage less than minimum
    function test_buildSingle_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert("Shiva:lev<min");
        buildSinglePosition(ONE, ONE - 1, posId, BASIC_SLIPPAGE);
    }

    // BuildSingle fail slippage greater than 10000
    function test_buildSingle_slippageGreaterThan100() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert("Shiva:slp>10000");
        buildSinglePosition(ONE, ONE, posId, 11000);
    }

    // Automator build a position on behalf of Alice
    function test_buildOnBehalfOf_ownership() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest = getBuildOnBehalfOfDigest(
            ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true
        );

        // sign the message as Alice
        bytes memory signature = getSignature(digest, alicePk);

        // execute `buildOnBehalfOf` with `automator`
        vm.prank(automator);
        uint256 posId = buildPositionOnBehalfOf(
            ONE, ONE, priceLimit, deadline, true, signature, alice
        );

        // the position is not associated with Alice in the ovMarket
        assertFractionRemainingIsZero(alice, posId);
        // the position is associated with Shiva in the ovMarket
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        // the position is associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    // build on behalf of fail expired deadline
    function test_buildOnBehalfOf_expiredDeadline() public {
        uint48 deadline = uint48(block.timestamp - 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest = getBuildOnBehalfOfDigest(
            ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true
        );

        // sign the message as Alice
        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        vm.prank(automator);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    // build on behalf of fail invalid signature (bad nonce)
    function test_buildOnBehalfOf_invalidSignature_badNonce() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest = getBuildOnBehalfOfDigest(
            ONE, ONE, priceLimit, shiva.nonces(alice) + 1, deadline, true
        );

        // sign the message as Alice
        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    // build on behalf of fail invalid signature (bad owner)
    function test_buildOnBehalfOf_invalidSignature_badOwner() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        bytes32 digest = getBuildOnBehalfOfDigest(
            ONE, ONE, priceLimit, shiva.nonces(alice), deadline, true
        );

        // sign the message as Bob
        bytes memory signature = getSignature(digest, bobPk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildPositionOnBehalfOf(ONE, ONE, priceLimit, deadline, true, signature, alice);
    }

    // Automator unwind a position on behalf of Alice
    function test_unwindOnBehalfOf_withdrawal() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest = getUnwindOnBehalfOfDigest(
            posId, ONE, priceLimit, shiva.nonces(alice), deadline
        );

        bytes memory signature = getSignature(digest, alicePk);

        // execute `unwindOnBehalfOf` with `automator`
        vm.prank(automator);
        unwindPositionOnBehalfOf(
            posId, ONE, priceLimit, deadline, signature, alice
        );

        // the position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    // unwind on behalf of fail expired deadline
    function test_unwindOnBehalfOf_expiredDeadline() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp - 1 hours);
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest = getUnwindOnBehalfOfDigest(
            posId, ONE, priceLimit, shiva.nonces(alice), deadline
        );

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        vm.prank(automator);
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);
    }

    // unwind on behalf of fail invalid signature (bad nonce)
    function test_unwindOnBehalfOf_invalidSignature_badNonce() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest = getUnwindOnBehalfOfDigest(
            posId, ONE, priceLimit, shiva.nonces(alice) + 1, deadline
        );

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);
    }

    // unwind on behalf of fail invalid signature (bad owner)
    function test_unwindOnBehalfOf_invalidSignature_badOwner() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        bytes32 digest = getUnwindOnBehalfOfDigest(
            posId, ONE, priceLimit, shiva.nonces(alice), deadline
        );

        // sign the message as Bob
        bytes memory signature = getSignature(digest, bobPk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        unwindPositionOnBehalfOf(posId, ONE, priceLimit, deadline, signature, alice);
    }

    // Automator builds a single position on behalf of Alice
    function test_buildSingleOnBehalfOf_ownership() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            ONE, ONE, posId1, shiva.nonces(alice), deadline
        );

        bytes memory signature = getSignature(digest, alicePk);

        // execute `buildSingleOnBehalfOf` with `automator`
        vm.prank(automator);
        uint256 posId2 = buildSinglePositionOnBehalfOf(
            ONE, ONE, posId1, BASIC_SLIPPAGE, deadline, signature, alice
        );

        // the first position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId1);
        // the second position is associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId2);
        // the second position is not associated with Alice in the ovMarket
        assertFractionRemainingIsZero(alice, posId2);
        // the second position is associated with Shiva in the ovMarket
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId2);
        // shiva has no tokens after the transaction
        assertOVTokenBalanceIsZero(address(shiva));
    }

    // build single on behalf of fail expired deadline
    function test_buildSingleOnBehalfOf_expiredDeadline() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp - 1 hours);

        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            ONE, ONE, posId1, shiva.nonces(alice), deadline
        );

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.ExpiredDeadline.selector);
        vm.prank(automator);
        buildSinglePositionOnBehalfOf(ONE, ONE, posId1, BASIC_SLIPPAGE, deadline, signature, alice);
    }

    // build single on behalf of fail invalid signature (bad nonce)
    function test_buildSingleOnBehalfOf_invalidSignature_badNonce() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            ONE, ONE, posId1, shiva.nonces(alice) + 1, deadline
        );

        bytes memory signature = getSignature(digest, alicePk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildSinglePositionOnBehalfOf(ONE, ONE, posId1, BASIC_SLIPPAGE, deadline, signature, alice);
    }

    // build single on behalf of fail invalid signature (bad owner)
    function test_buildSingleOnBehalfOf_invalidSignature_badOwner() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            ONE, ONE, posId1, shiva.nonces(alice), deadline
        );

        // sign the message as Bob
        bytes memory signature = getSignature(digest, bobPk);

        vm.expectRevert(IShiva.InvalidSignature.selector);
        vm.prank(automator);
        buildSinglePositionOnBehalfOf(ONE, ONE, posId1, BASIC_SLIPPAGE, deadline, signature, alice);
    }

}
