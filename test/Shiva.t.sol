// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Shiva} from "src/Shiva.sol";
import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {Constants} from "./utils/Constants.sol";
import {Utils} from "src/utils/Utils.sol";
import {OverlayV1Factory} from "v1-periphery/lib/v1-core/contracts/OverlayV1Factory.sol";
import {OverlayV1Token} from "v1-periphery/lib/v1-core/contracts/OverlayV1Token.sol";
import {Risk} from "v1-periphery/lib/v1-core/contracts/libraries/Risk.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";

contract ShivaTest is Test, ShivaTestBase {
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
        vm.expectRevert();
        shiva.build(
            ShivaStructs.Build(ovMarket, true, ONE, ONE - 1, priceLimit)
        );
    }

    // Build fail not enough allowance
    function test_build_notEnoughAllowance() public {
        deal(address(ovToken), charlie, 1000e18);
        vm.startPrank(charlie);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(
            ShivaStructs.Build(ovMarket, true, ONE, ONE, priceLimit)
        );
    }

    // Build fail enough allowance but not enough balance considering the trading fee
    function test_build_notEnoughBalance() public {
        deal(address(ovToken), charlie, ONE);
        vm.startPrank(charlie);
        ovToken.approve(address(shiva), type(uint256).max);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(
            ShivaStructs.Build(ovMarket, true, ONE, ONE, priceLimit)
        );
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
        vm.expectRevert();
        shiva.unwind(
            ShivaStructs.Unwind(ovMarket, posId, ONE, priceLimit)
        );
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
        vm.expectRevert();
        buildSinglePosition(ONE, ONE, 0, BASIC_SLIPPAGE);
    }

    // BuildSingle fail leverage less than minimum
    function test_buildSingle_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        buildSinglePosition(ONE, ONE - 1, posId, BASIC_SLIPPAGE);
    }

    // BuildSingle fail slippage greater than 10000
    function test_buildSingle_slippageGreaterThan100() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        buildSinglePosition(ONE, ONE, posId, 11000);
    }

    function test_buildOnBehalfOf_ownership() public {
        uint48 deadline = uint48(block.timestamp + 1 hours);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);

        // create message hash
        bytes32 structHash = keccak256(abi.encode(
            shiva.BUILD_ON_BEHALF_OF_TYPEHASH(),
            ovMarket,
            deadline,
            ONE,
            ONE,
            true,
            priceLimit,
            shiva.nonces(alice)
        ));
        bytes32 digest = shiva.getDigest(structHash);

        // sign the message as Alice
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // execute `buildOnBehalfOf` with `automator`
        vm.prank(automator);
        uint256 posId = shiva.build(
            ShivaStructs.BuildOnBehalfOf(ovMarket, deadline, ONE, ONE, priceLimit, signature, address(alice), true)
        );

        (,,,,,,,uint16 fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0);

        assertEq(shiva.positionOwners(ovMarket, posId), alice);
    }

    function test_unwindOnBehalfOf_withdrawal() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        // Alice unwinds her position through a signed message
        uint48 deadline = uint48(block.timestamp + 1 hours);
        (uint256 priceLimit,) = Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);

        // create message hash
        bytes32 structHash = keccak256(abi.encode(
            shiva.UNWIND_ON_BEHALF_OF_TYPEHASH(),
            ovMarket,
            deadline,
            posId,
            ONE,
            priceLimit,
            shiva.nonces(alice)
        ));
        bytes32 digest = shiva.getDigest(structHash);

        // sign the message as Alice
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // execute `unwindOnBehalfOf` with `automator`
        vm.prank(automator);
        shiva.unwind(
            ShivaStructs.UnwindOnBehalfOf(ovMarket, deadline, posId, ONE, priceLimit, signature, address(alice))
        );

        (,,,,,,,uint16 fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);
    }

    function test_buildSingleOnBehalfOf_ownership() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();

        uint48 deadline = uint48(block.timestamp + 1 hours);

        // create message hash
        bytes32 structHash = keccak256(abi.encode(
            shiva.BUILD_SINGLE_ON_BEHALF_OF_TYPEHASH(),
            ovMarket,
            deadline,
            true,
            ONE,
            ONE,
            posId1,
            shiva.nonces(alice)
        ));
        bytes32 digest = shiva.getDigest(structHash);

        // sign the message as Alice
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // execute `buildSingleOnBehalfOf` with `automator`
        vm.prank(automator);
        uint256 posId2 = shiva.buildSingle(
            ShivaStructs.BuildSingleOnBehalfOf(
                ovMarket, deadline, BASIC_SLIPPAGE, true, ONE, ONE, posId1, signature, address(alice)
            )
        );

        // the first position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId1)));
        assertEq(fractionRemaining, 0);

        // the second position is associated with Alice in Shiva
        assertEq(shiva.positionOwners(ovMarket, posId2), alice);

        // the second position is not associated with Alice in the ovMarket
        (,,,,,,, fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(alice, posId2)));
        assertEq(fractionRemaining, 0);

        // shiva has no tokens after the transaction
        assertEq(ovToken.balanceOf(address(shiva)), 0);
    }
}
