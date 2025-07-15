// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {IShiva} from "src/IShiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {Utils} from "src/utils/Utils.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";

/**
 * @title ShivaRelayerTest
 * @notice Test suite for the relayer functionalities in Shiva contract
 */
contract ShivaRelayerTest is ShivaTestBase {
    using FixedPoint for uint256;
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
     * @dev Test that limit order build with relayer fee calculates and pays the fee correctly
     */
    function test_limitOrderBuild_with_relayer_fee() public {
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
        uint256 relayerBalanceBefore = ovlToken.balanceOf(automator);
        assertEq(relayerBalanceBefore, 0, "Relayer should have no OVL initially");

        vm.prank(automator);
        shiva.limitOrderBuild(
            ShivaStructs.Build(ovlMarket, 0, true, collateral, leverage, type(uint256).max),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );

        // Check that relayer received the fee
        uint256 relayerBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(relayerBalanceAfter, relayerBalanceBefore, "Relayer should receive a fee");
    }

    /**
     * @dev Test that take profit with relayer fee calculates and pays the fee correctly
     */
    function test_takeProfit_with_relayer_fee() public {
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
        uint256 relayerBalanceBefore = ovlToken.balanceOf(charlie);
        assertEq(relayerBalanceBefore, 0, "Relayer should have no OVL initially");

        // Give relayer gas money
        vm.deal(charlie, 1 ether);

        vm.startPrank(charlie);
        shiva.takeProfit(
            ShivaStructs.Unwind(ovlMarket, 0, posId, ONE, priceLimit),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature)
        );
        vm.stopPrank();

        // Check that relayer received the fee
        uint256 relayerBalanceAfter = ovlToken.balanceOf(charlie);
        assertGt(relayerBalanceAfter, relayerBalanceBefore, "Relayer should receive a fee");
    }

    /**
     * @dev Test that unwind reverts if the unwind amount is insufficient to pay the relayer fee
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

        // Give relayer gas money to avoid out-of-gas issues
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
     * @dev Test that buildSingle with relayer fee calculates and pays the fee correctly
     */
    function test_buildSingle_with_relayer_fee() public {
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

        uint256 relayerBalanceBefore = ovlToken.balanceOf(automator);
        assertEq(relayerBalanceBefore, 0, "Relayer should have no OVL initially");

        // Automator executes the transaction for Bob
        vm.startPrank(automator);
        shiva.buildSingle(
            ShivaStructs.BuildSingle(
                ovlMarket, 0, unwindPriceLimit, buildPriceLimit, newCollateral, leverage, posId
            ),
            ShivaStructs.OnBehalfOf(bob, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            true // payRelayerFee
        );
        vm.stopPrank();

        uint256 relayerBalanceAfter = ovlToken.balanceOf(automator);
        assertGt(relayerBalanceAfter, relayerBalanceBefore, "Relayer should receive a fee");
    }

    /**
     * @dev Test that when payRelayerFee is false, no fee is paid
     */
    function test_no_relayer_fee_when_false() public {
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

        uint256 relayerBalanceBefore = ovlToken.balanceOf(bob);

        // Bob executes the transaction for Alice
        vm.startPrank(bob);
        shiva.buildSingle(
            ShivaStructs.BuildSingle(
                ovlMarket, 0, unwindPriceLimit, buildPriceLimit, newCollateral, leverage, posId
            ),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            false // payRelayerFee
        );
        vm.stopPrank();

        uint256 relayerBalanceAfter = ovlToken.balanceOf(bob);
        assertEq(relayerBalanceAfter, relayerBalanceBefore, "Relayer should not receive fee");
    }
} 