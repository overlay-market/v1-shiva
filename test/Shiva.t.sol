// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ShivaStructs} from "src/ShivaStructs.sol";
import {Utils} from "src/utils/Utils.sol";
import {IShiva} from "src/IShiva.sol";
import {Constants} from "./utils/Constants.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";

import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {Position} from "v1-core/contracts/libraries/Position.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";

/**
 * @title ShivaTest
 * @notice Test suite for the Shiva contract
 * @dev This contract uses a forked network to test the Shiva contract
 * @dev The forked network is Bartio Berachain
 */
contract ShivaTest is Test, ShivaTestBase {
    using FixedPoint for uint256;

    /**
     * @dev Group of tests for the Shiva contract setup
     */

    /**
     * @notice Tests that adding an authorized factory works
     */
    function test_addAuthorizedFactory() public {
        addAuthorizedFactory();
    }

    /**
     * @notice Tests that removing an authorized factory works
     */
    function test_removeAuthorizedFactory() public {
        removeAuthorizedFactory();
    }

    /**
     * @notice Tests that building a position through Shiva fails due to an unauthorized factory
     */
    function test_build_unauthorizedFactory() public {
        // Governor removes the authorized factory; this is already added in the setup
        removeAuthorizedFactory();

        vm.startPrank(alice);
        vm.expectRevert(IShiva.MarketNotValid.selector);
        shiva.build(ShivaStructs.Build(ovMarket, BROKER_ID, true, ONE, ONE, BASIC_SLIPPAGE));
    }

    /**
     * @notice Tests that adding an authorized factory fails due to the caller not being authorized
     */
    function test_addAuthorizedFactory_notGovernor() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shiva.addFactory(IOverlayV1Factory(address(0)));
    }

    /**
     * @notice Tests that removing an authorized factory fails due to the caller not being authorized
     */
    function test_removeAuthorizedFactory_notGovernor() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shiva.removeFactory(IOverlayV1Factory(address(0)));
    }

    /**
     * @dev Group of tests for the build method
     */

    /**
     * @notice Tests building a position through Shiva
     */
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

    /**
     * @notice Tests that after building a position, Shiva does not have OVL tokens
     */
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

    /**
     * @notice Tests that building a position through Shiva fails due to the leverage being less than the minimum
     */
    function test_build_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert("Shiva:lev<min");
        shiva.build(ShivaStructs.Build(ovMarket, BROKER_ID, true, ONE, ONE - 1, priceLimit));
    }

    /**
     * @notice Tests that building a position through Shiva fails due to not enough allowance
     */
    function test_build_notEnoughAllowance() public {
        deal(address(ovToken), charlie, 1000e18);
        vm.startPrank(charlie);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(ShivaStructs.Build(ovMarket, BROKER_ID, true, ONE, ONE, priceLimit));
    }

    /**
     * @notice Tests that building a position through Shiva fails due to not enough balance
     * considering the trading fee
     */
    function test_build_notEnoughBalance() public {
        deal(address(ovToken), charlie, ONE);
        vm.startPrank(charlie);
        ovToken.approve(address(shiva), type(uint256).max);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(ShivaStructs.Build(ovMarket, BROKER_ID, true, ONE, ONE, priceLimit));
    }

    /**
     * @notice Tests that building a position through Shiva fails due to Shiva being paused
     */
    function test_build_pausedShiva() public {
        pauseShiva();
        vm.startPrank(alice);
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert("Pausable: paused");
        shiva.build(ShivaStructs.Build(ovMarket, BROKER_ID, true, ONE, ONE, priceLimit));
    }

    /**
     * @notice Tests that building a position through Shiva works after unpausing Shiva
     */
    function test_build_afterUnpause() public {
        pauseShiva();
        unpauseShiva();
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // the position is not associated with Alice in the ovMarket
        assertFractionRemainingIsZero(alice, posId);
        // the position is associated with Shiva in the ovMarket
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId);
        // the position is associated with Alice in Shiva
        assertUserIsPositionOwnerInShiva(alice, posId);
    }

    /**
     * @notice Tests that balance of the reward vault is equal to the notional amount of receipt tokens
     * after building a position
     */
    function test_build_pol_stake() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), notional);
    }

    error InsufficientSelfStake();

    /**
     * @notice Tests that balance of the reward vault is equal to the notional amount of receipt tokens
     * after building a position and then fails to withdraw the notional amount of receipt tokens
     */
    function test_build_pol_stake_revert_user_withdraw() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), notional);

        vm.expectRevert(InsufficientSelfStake.selector);
        rewardVault.withdraw(notional);

        vm.expectRevert(InsufficientSelfStake.selector);
        rewardVault.exit();
    }

    /**
     * @dev Group of tests for the unwind method
     */

    /**
     * @notice Tests unwinding a position through Shiva
     */
    function test_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, ONE, BASIC_SLIPPAGE);

        // the position is successfully unwound
        assertFractionRemainingIsZero(address(shiva), posId);
    }

    /**
     * @notice Tests unwinding a fraction of a position through Shiva
     */
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

    /**
     * @notice Tests unwinding a position through Shiva fails due to the caller not being the owner of the position
     */
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
        shiva.unwind(ShivaStructs.Unwind(ovMarket, BROKER_ID, posId, ONE, priceLimit));
    }

    /**
     * @notice Tests unwinding a position through Shiva fails due to Shiva being paused
     */
    function test_unwind_pausedShiva() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();
        // Alice unwinds her position through Shiva
        pauseShiva();
        vm.startPrank(alice);
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), ONE, BASIC_SLIPPAGE);
        vm.expectRevert("Pausable: paused");
        shiva.unwind(ShivaStructs.Unwind(ovMarket, BROKER_ID, posId, ONE, priceLimit));
    }

    /**
     * @notice Tests emergency withdrawing a position through Shiva
     */

    /**
     * @notice Tests emergency withdrawing a position through Shiva
     */
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

    /**
     * @notice Tests emergency withdrawing a position through Shiva fails due to the caller not
     * being the owner of the position
     */
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

    /**
     * @notice Tests emergency withdrawing a position through Shiva fails due to Shiva being paused
     */
    function test_emergencyWithdraw_pausedShiva() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();
        // Alice emergency withdraws her position through Shiva
        pauseShiva();
        shutDownMarket();
        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
        shiva.emergencyWithdraw(ovMarket, posId, alice);
    }

    /**
     * @dev Group of tests for the stake rewards workflow
     */

    /**
     * @notice Tests that the reward vault balance is zero after unwinding a position
     */
    function test_unwind_pol_unstake() public {
        vm.startPrank(alice);
        uint256 collateral = 2e18;
        uint256 leverage = 3e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), notional);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, ONE, 1);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);

        assertEq(rewardVault.balanceOf(alice), 0);
    }

    /**
     * @notice Tests that the reward vault balance changes after unwinding a fraction of a position
     */
    function test_partial_unwind_pol_unstake() public {
        vm.startPrank(alice);
        uint256 collateral = 2e18;
        uint256 leverage = 3e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), notional);

        // Alice unwinds her position through Shiva
        uint256 fraction = ONE / 2;
        unwindPosition(posId, fraction, 1);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 10_000 * (ONE - fraction) / ONE);

        assertEq(rewardVault.balanceOf(alice), (ONE - fraction).mulUp(notional));

        unwindPosition(posId, fraction, 1);
        assertEq(
            rewardVault.balanceOf(alice), (ONE - fraction).mulUp(ONE - fraction).mulUp(notional)
        );

        unwindPosition(posId, ONE, 1);
        assertEq(rewardVault.balanceOf(alice), 0);
    }

    /**
     * @notice Tests the partial unwinding of a leveraged position and the corresponding unstaking of receipt tokens.
     * @param collateral The initial collateral amount.
     * @param leverage The leverage applied to the position.
     * @param fraction The fraction of the position to unwind.
     *
     * This test verifies:
     * - The initial staking of the notional amount of receipt tokens on behalf of the user.
     * - The correct unwinding of the position and the corresponding updates to the user's reward balance.
     * - The remaining fraction of the position after each unwind operation.
     * - The final state where the position is fully unwound and the reward balance is zero.
     */
    function testFuzz_partial_unwind_pol_unstake(
        uint256 collateral,
        uint256 leverage,
        uint256 fraction
    ) public {
        collateral =
            bound(collateral, ovMarket.params(uint256(Risk.Parameters.MinCollateral)), 500e18);
        leverage = bound(leverage, 1e18, ovMarket.params(uint256(Risk.Parameters.CapLeverage)));
        fraction = bound(leverage, 1e17, 9e17);
        console.log(fraction, "fraction");
        uint256 roundedFraction = fraction - fraction % 1e14;
        console.log(roundedFraction, "roundedFraction");
        vm.startPrank(alice);
        ovToken.transfer(address(ovMarket), 2);
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        console.log(notional, "notional");
        assertEq(rewardVault.balanceOf(alice), notional);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, fraction, 1);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 10_000 * (ONE - roundedFraction) / ONE, "fraction remaining");

        assertApproxEqAbs(
            rewardVault.balanceOf(alice),
            (ONE - roundedFraction).mulDown(notional),
            1,
            "reward balance, 1st unwind"
        );

        {
            (
                uint96 notionalInitial_,
                uint96 debtInitial_,
                int24 midTick_,
                int24 entryTick_,
                bool isLong_,
                bool liquidated_,
                uint240 oiShares_,
                uint16 fractionRemaining_
            ) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
            Position.Info memory positionInfo = Position.Info(
                notionalInitial_,
                debtInitial_,
                midTick_,
                entryTick_,
                isLong_,
                liquidated_,
                oiShares_,
                fractionRemaining_
            );
            assertEq(
                rewardVault.balanceOf(alice),
                Position.notionalInitial(positionInfo, ONE),
                "1st unwind: reward balance != remaining intial notional"
            );
        }

        unwindPosition(posId, fraction, 1);
        // estimated notional remaining on position
        assertApproxEqRel(
            rewardVault.balanceOf(alice),
            (ONE - roundedFraction).mulDown(ONE - roundedFraction).mulDown(notional),
            1e16,
            "reward balance, 2nd unwind"
        );
        // staked balance should be lower than or equal the estimated notional remaining on position (+1 for rounding error)
        assertLeDecimal(
            rewardVault.balanceOf(alice),
            (ONE - roundedFraction).mulDown(ONE - roundedFraction).mulDown(notional) + 1,
            1e18,
            "reward balance, 2nd unwind LE"
        );

        {
            (
                uint96 notionalInitial_,
                uint96 debtInitial_,
                int24 midTick_,
                int24 entryTick_,
                bool isLong_,
                bool liquidated_,
                uint240 oiShares_,
                uint16 fractionRemaining_
            ) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
            Position.Info memory positionInfo = Position.Info(
                notionalInitial_,
                debtInitial_,
                midTick_,
                entryTick_,
                isLong_,
                liquidated_,
                oiShares_,
                fractionRemaining_
            );
            assertEq(
                rewardVault.balanceOf(alice),
                Position.notionalInitial(positionInfo, ONE),
                "2nd unwind: reward balance != remaining intial notional"
            );
        }

        unwindPosition(posId, ONE, 1);
        (,,,,,,, uint16 fractionRemaining3) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining3, 0, "3rd unwind: fraction remaining != 0");
        assertEq(rewardVault.balanceOf(alice), 0, "3rd unwind: reward balance != 0");
    }

    /**
     * @dev Group of tests for the buildSingle method
     */

    /**
     * @notice Tests building a position through Shiva and then building another one using buildSingle
     */
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

    /**
     * @notice Tests fuzzing the buildSingle method
     */
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

        assertFractionRemainingIsZero(address(shiva), posId1);
        assertUserIsPositionOwnerInShiva(alice, posId2);
        assertFractionRemainingIsZero(alice, posId2);
        assertFractionRemainingIsGreaterThanZero(address(shiva), posId2);
        assertOVTokenBalanceIsZero(address(shiva));
    }

    /**
     * @notice Tests after building a position, Shiva does not have OVL tokens
     */
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

    /**
     * @notice Tests building a position fails due to Shiva being paused
     */
    function test_buildSingle_pausedShiva() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.stopPrank();
        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);
        // Alice builds a second position after a while
        pauseShiva();
        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
        buildSinglePosition(ONE, ONE, posId, BASIC_SLIPPAGE);
    }

    /**
     * @notice Tests building a position fails due to the previous position not being owned by the caller
     */
    function test_buildSingle_noPreviousPosition() public {
        vm.startPrank(alice);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        buildSinglePosition(ONE, ONE, 0, BASIC_SLIPPAGE);
    }

    /**
     * @notice Tests building a position fails due to the leverage being less than the minimum
     */
    function test_buildSingle_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert("Shiva:lev<min");
        buildSinglePosition(ONE, ONE - 1, posId, BASIC_SLIPPAGE);
    }

    /**
     * @notice Tests building a position fails due to the slippage being greater than 10000
     */
    function test_buildSingle_slippageGreaterThan100() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert("Shiva:slp>10000");
        buildSinglePosition(ONE, ONE, posId, 11000);
    }

    /**
     * @notice Tests rewards value are zero after emergency withdrawing a position
     */
    function test_pol_withdraw_emergencyWithdraw_function() public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        assertEq(rewardVault.balanceOf(alice), ONE);

        unwindPosition(posId, 0.123e18, BASIC_SLIPPAGE);
        vm.stopPrank();

        vm.startPrank(Constants.getGovernorAddress());
        ovFactory.shutdown(ovMarket.feed());
        vm.stopPrank();

        vm.startPrank(alice);
        shiva.emergencyWithdraw(ovMarket, posId, alice);
        vm.stopPrank();

        assertEq(rewardVault.balanceOf(alice), 0);
    }
}
