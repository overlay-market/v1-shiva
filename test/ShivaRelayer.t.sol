// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test} from "forge-std/Test.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {IShiva} from "src/IShiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {Utils} from "src/utils/Utils.sol";

/**
 * @title ShivaRelayerTest
 * @notice Test suite for the relayer functionalities in Shiva contract
 */
contract ShivaRelayerTest is ShivaTestBase {
    /**
     * @dev Sets up the initial state for the test contract.
     */
    function setUp() public override {
        super.setUp();
        
        // Set initial relayer fee to 1 OVL
        vm.startPrank(deployer);
        shiva.setRelayerFee(1e18);
        vm.stopPrank();
    }

    /**
     * @dev Group of tests for the relayer fee
     */

    /**
     * @dev Test that the governor can set the relayer fee
     */
    function test_setRelayerFee() public {
        uint256 newFee = 0.5e18; // 0.5 OVL

        vm.startPrank(deployer);
        shiva.setRelayerFee(newFee);
        vm.stopPrank();

        assertEq(shiva.relayerFee(), newFee, "Relayer fee should be updated");
    }

    /**
     * @dev Test that a non-governor cannot set the relayer fee
     */
    function test_revert_setRelayerFee_not_governor() public {
        uint256 newFee = 0.5e18; // 0.5 OVL

        vm.startPrank(alice);
        vm.expectRevert("Shiva: !governor");
        shiva.setRelayerFee(newFee);
        vm.stopPrank();
    }

    /**
     * @dev Test that build with relayer fee calculates and pays the fee correctly
     */
    function test_build_with_relayer_fee() public {
        uint256 fixedFee = 0.1e18;
        vm.startPrank(deployer);
        shiva.setRelayerFee(fixedFee);
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;
        uint256 notional = collateral * leverage / 1e18;

        // Calculate proper price limit
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, collateral, leverage, BASIC_SLIPPAGE, true);

        // Get digest and signature for build on behalf of
        bytes32 digest = getBuildOnBehalfOfDigest(
            collateral, leverage, priceLimit, FIXED_NONCE, uint48(block.timestamp + 3600), true, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Get initial balances
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        uint256 relayerBalanceBefore = ovlToken.balanceOf(msg.sender);

        // Execute build on behalf of with relayer fee
        vm.prank(msg.sender);
        shiva.build(
            ShivaStructs.Build(ovlMarket, 0, true, collateral, leverage, priceLimit),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            true // payRelayerFee
        );

        // Check that relayer received the fee
        uint256 relayerBalanceAfter = ovlToken.balanceOf(msg.sender);
        uint256 actualRelayerFee = relayerBalanceAfter - relayerBalanceBefore;

        assertEq(actualRelayerFee, fixedFee, "Relayer should receive fixed fee");

        // Check that Alice paid the correct amount (collateral + trading fee + relayer fee)
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        uint256 tradingFee = (notional * 750000000000000) / 1e18;
        uint256 expectedTotalPaid = collateral + tradingFee + fixedFee;
        uint256 actualTotalPaid = aliceBalanceBefore - aliceBalanceAfter;

        assertEq(actualTotalPaid, expectedTotalPaid, "Alice should pay correct total amount");
    }

    /**
     * @dev Test that unwind with relayer fee calculates and pays the fee correctly
     */
    function test_unwind_with_relayer_fee() public {
        uint256 fixedFee = 0.2e18;
        vm.startPrank(deployer);
        shiva.setRelayerFee(fixedFee);
        vm.stopPrank();

        // First build a position
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        vm.stopPrank();

        // Get digest and signature for unwind on behalf of
        bytes32 digest =
            getUnwindOnBehalfOfDigest(posId, ONE, 0, FIXED_NONCE, uint48(block.timestamp + 3600), 0);
        bytes memory signature = getSignature(digest, alicePk);

        // Record balances before
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        uint256 relayerBalanceBefore = ovlToken.balanceOf(bob);

        // Unwind position with relayer fee
        vm.startPrank(bob);
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, 0, posId, ONE, 0),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            true // payRelayerFee
        );
        vm.stopPrank();

        // Check that relayer received the fee
        uint256 relayerBalanceAfter = ovlToken.balanceOf(bob);
        assertEq(
            relayerBalanceAfter - relayerBalanceBefore, fixedFee, "Relayer should receive fixed fee"
        );

        // Check that alice received the remaining amount
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        uint256 aliceReceived = aliceBalanceAfter - aliceBalanceBefore;
        
        // Alice should have received some amount (the unwind proceeds minus the relayer fee)
        assertGt(aliceReceived, 0, "Alice should receive some amount from unwind");
    }

    /**
     * @dev Test that unwind reverts if the unwind amount is insufficient to pay the relayer fee
     */
    function test_revert_unwind_insufficient_for_fee() public {
        // Set a high relayer fee that likely won't be covered
        uint256 highFee = 500e18; // 500 OVL, very high
        vm.startPrank(deployer);
        shiva.setRelayerFee(highFee);
        vm.stopPrank();

        // Build a small position
        vm.startPrank(alice);
        uint256 posId = buildPosition(10e18, 1e18, 1, true); // small 10 OVL position
        vm.stopPrank();

        // Get digest and signature for unwind on behalf of
        bytes32 digest =
            getUnwindOnBehalfOfDigest(posId, ONE, 0, FIXED_NONCE, uint48(block.timestamp + 3600), 0);
        bytes memory signature = getSignature(digest, alicePk);

        // Expect revert when unwinding
        vm.startPrank(bob);
        vm.expectRevert();
        shiva.unwind(
            ShivaStructs.Unwind(ovlMarket, 0, posId, ONE, 0),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            true // payRelayerFee
        );
        vm.stopPrank();
    }

    /**
     * @dev Test that buildSingle with relayer fee calculates and pays the fee correctly
     */
    function test_buildSingle_with_relayer_fee() public {
        uint256 fixedFee = 0.3e18;
        _setRelayerFee(fixedFee);

        // Prepare previous position data
        uint256 posId = _buildInitialPosition();
        uint256 newCollateral = 50e18;
        uint256 leverage = 2e18;

        // Prepare price limits and signature
        (uint256 unwindPriceLimit, uint256 buildPriceLimit, bytes memory signature) =
            _prepareBuildSingleParams(posId, newCollateral, leverage);

        // Balances before
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        uint256 relayerBalanceBefore = ovlToken.balanceOf(msg.sender);

        // Execute action
        _executeBuildSingleWithRelayerFee(
            newCollateral, leverage, posId, unwindPriceLimit, buildPriceLimit, signature
        );

        // Assert relayer received the fee
        uint256 relayerBalanceAfter = ovlToken.balanceOf(msg.sender);
        assertEq(relayerBalanceAfter - relayerBalanceBefore, fixedFee, "Relayer should receive fixed fee");

        // Assert Alice paid the correct amount
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        uint256 actualTotalPaid = aliceBalanceBefore - aliceBalanceAfter;
        // The total collateral for the new position is (unwound amount + new collateral)
        // We can't know the exact unwound amount beforehand due to PnL.
        // But we know Alice must pay at least the new collateral + trading fee on new collateral + relayer fee.
        assertGt(actualTotalPaid, newCollateral + fixedFee, "Alice should pay more than just new collateral + fee");
    }

    function _setRelayerFee(uint256 fee) private {
        vm.startPrank(deployer);
        shiva.setRelayerFee(fee);
        vm.stopPrank();
    }

    function _buildInitialPosition() private returns (uint256) {
        vm.startPrank(alice);
        uint256 posId = buildPosition(100e18, 2e18, 1, true);
        vm.stopPrank();
        return posId;
    }

    function _prepareBuildSingleParams(
        uint256 posId,
        uint256 newCollateral,
        uint256 leverage
    ) private view returns (uint256 unwindPriceLimit, uint256 buildPriceLimit, bytes memory signature) {
        unwindPriceLimit = Utils.getUnwindPrice(ovlState, ovlMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);
        // Estimate price for the *total* collateral to be built
        // Note: this is an approximation as we don't know the exact unwind amount yet
        uint256 estimatedTotalCollateral = newCollateral + 100e18; // new + estimated old
        buildPriceLimit = Utils.getEstimatedPrice(ovlState, ovlMarket, estimatedTotalCollateral, leverage, BASIC_SLIPPAGE, true);
        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            newCollateral, leverage, posId, FIXED_NONCE, unwindPriceLimit, buildPriceLimit, uint48(block.timestamp + 3600), 0
        );
        signature = getSignature(digest, alicePk);
    }

    function _executeBuildSingleWithRelayerFee(
        uint256 newCollateral,
        uint256 leverage,
        uint256 posId,
        uint256 unwindPriceLimit,
        uint256 buildPriceLimit,
        bytes memory signature
    ) private {
        vm.prank(msg.sender);
        shiva.buildSingle(
            ShivaStructs.BuildSingle(ovlMarket, 0, unwindPriceLimit, buildPriceLimit, newCollateral, leverage, posId),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            true // payRelayerFee
        );
    }

    /**
     * @dev Test that when payRelayerFee is false, no fee is paid
     */
    function test_no_relayer_fee_when_false() public {
        // Set a high relayer fee to make it obvious if it's paid
        vm.startPrank(deployer);
        shiva.setRelayerFee(10e18); // 10 OVL
        vm.stopPrank();

        uint256 collateral = 100e18;
        uint256 leverage = 2e18;

        // Calculate proper price limit
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, collateral, leverage, BASIC_SLIPPAGE, true);

        // Get digest and signature for build on behalf of
        bytes32 digest = getBuildOnBehalfOfDigest(
            collateral, leverage, priceLimit, FIXED_NONCE, uint48(block.timestamp + 3600), true, 0
        );
        bytes memory signature = getSignature(digest, alicePk);

        // Record balances before
        uint256 aliceBalanceBefore = ovlToken.balanceOf(alice);
        uint256 relayerBalanceBefore = ovlToken.balanceOf(bob);

        // Build position without relayer fee
        vm.startPrank(bob);
        shiva.build(
            ShivaStructs.Build(ovlMarket, 0, true, collateral, leverage, priceLimit),
            ShivaStructs.OnBehalfOf(alice, uint48(block.timestamp + 3600), FIXED_NONCE, signature),
            false // payRelayerFee
        );
        vm.stopPrank();

        // Check that relayer did not receive any fee
        uint256 relayerBalanceAfter = ovlToken.balanceOf(bob);
        assertEq(relayerBalanceAfter, relayerBalanceBefore, "Relayer should not receive fee");

        // Check that alice paid collateral + trading fee (no relayer fee)
        uint256 aliceBalanceAfter = ovlToken.balanceOf(alice);
        uint256 notional = collateral * leverage / 1e18;
        uint256 tradingFee = (notional * 750000000000000) / 1e18;
        uint256 expectedPaid = collateral + tradingFee;
        assertEq(aliceBalanceBefore - aliceBalanceAfter, expectedPaid, "Alice should pay collateral + trading fee");
    }
} 