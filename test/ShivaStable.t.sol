// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Shiva} from "src/Shiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {LoanBasedStableCollateral} from "src/LoanBasedStableCollateral.sol";
import {IShiva} from "src/IShiva.sol";
import {Utils} from "src/utils/Utils.sol";

import {ShivaTestBase} from "./ShivaBase.t.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract ShivaStableTest is Test, ShivaTestBase {
    function test_build_stable_pausedShiva() public {
        pauseShiva();

        ShivaStructs.BuildStable memory params =
            getBuildStableParams(1_000e18, ONE, BASIC_SLIPPAGE, true, 0);

        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
        shiva.buildStable(params);
        vm.stopPrank();
    }

    function testFuzz_build_stable(
        bool isLong,
        uint256 stableCollateral,
        uint256 leverage
    ) public {
        uint256 maxStableCollateral = 50_000e18;
        stableCollateral = bound(stableCollateral, 1e18, maxStableCollateral);
        leverage = bound(leverage, ONE, 5e18);

        ShivaStructs.BuildStable memory params =
            getBuildStableParams(stableCollateral, leverage, BASIC_SLIPPAGE, isLong, 0);

        vm.startPrank(alice);
        uint256 positionId = shiva.buildStable(params);
        vm.stopPrank();

        assertFractionRemainingIsZero(alice, positionId);
        assertFractionRemainingIsGreaterThanZero(address(shiva), positionId);
        assertUserIsPositionOwnerInShiva(alice, positionId);

        uint256 loanId = shiva.loanIds(ovlMarket, positionId);
        assertGt(loanId, 0, "LBSC loan should be tracked");

        (address borrower, uint256 collateral, uint256 debt, , bool settled) = lbsc.loans(loanId);
        assertEq(borrower, alice, "loan borrower mismatch");
        assertEq(collateral, stableCollateral, "loan collateral mismatch");
        assertGt(debt, 0, "loan debt should be > 0");
        assertFalse(settled, "loan should be active");

        assertOVLTokenBalanceIsZero(address(shiva));
    }

    function test_build_stable_notEnoughStableBalance() public {
        vm.startPrank(alice);
        stableToken.transfer(bob, stableToken.balanceOf(alice));
        vm.stopPrank();

        ShivaStructs.BuildStable memory params =
            getBuildStableParams(1_000e18, 2e18, BASIC_SLIPPAGE, true, 0);

        assertEq(stableToken.balanceOf(alice), 0, "alice should have no stables");

        vm.startPrank(alice);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        shiva.buildStable(params);
        vm.stopPrank();
    }

    function test_build_stable_notEnoughStableAllowance() public {
        vm.prank(alice);
        stableToken.approve(address(lbsc), 0);

        ShivaStructs.BuildStable memory params =
            getBuildStableParams(1_000e18, 2e18, BASIC_SLIPPAGE, true, 0);

        vm.startPrank(alice);
        vm.expectRevert("ERC20: insufficient allowance");
        shiva.buildStable(params);
        vm.stopPrank();
    }

    function test_build_stable_leverageBelowMinimum() public {
        ShivaStructs.BuildStable memory params = ShivaStructs.BuildStable({
            ovlMarket: ovlMarket,
            brokerId: BROKER_ID,
            isLong: true,
            stableCollateral: 1_000e18,
            leverage: ONE - 1,
            priceLimit: type(uint256).max,
            minOvl: 0
        });

        vm.startPrank(alice);
        vm.expectRevert(bytes("Shiva:lev<min"));
        shiva.buildStable(params);
        vm.stopPrank();
    }

    function test_build_stable_afterUnpause() public {
        pauseShiva();
        unpauseShiva();

        vm.startPrank(alice);
        uint256 positionId = buildStablePosition(1_000e18, 2e18, BASIC_SLIPPAGE, true, 0);
        vm.stopPrank();

        assertFractionRemainingIsZero(alice, positionId);
        assertFractionRemainingIsGreaterThanZero(address(shiva), positionId);
        assertUserIsPositionOwnerInShiva(alice, positionId);
        uint256 loanId = shiva.loanIds(ovlMarket, positionId);
        assertGt(loanId, 0, "LBSC loan should be tracked");
    }

    function test_unwind_stable_fullPositionSettlesLoan() public {
        uint256 initialStableBalance = stableToken.balanceOf(alice);
        uint256 stableCollateral = 5_000e18;

        vm.startPrank(alice);
        uint256 positionId = buildStablePosition(stableCollateral, 2e18, BASIC_SLIPPAGE, true, 0);
        uint256 stableBalanceAfterBuild = stableToken.balanceOf(alice);
        uint256 loanId = shiva.loanIds(ovlMarket, positionId);
        assertGt(loanId, 0, "LBSC loan should be tracked");
        _assertLbscCollateralAccounting(1);

        (
            address borrower,
            uint256 collateral,
            uint256 debt,
            ,
            bool settledBefore
        ) = lbsc.loans(loanId);
        assertEq(borrower, alice, "loan borrower mismatch");
        assertEq(collateral, stableCollateral, "loan collateral mismatch");
        assertGt(debt, 0, "loan debt should be > 0");
        assertFalse(settledBefore, "loan should be active");

        unwindPosition(positionId, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        (, , , , bool settledAfter) = lbsc.loans(loanId);
        assertTrue(settledAfter, "loan should be settled");
        assertEq(lbsc.totalOutstandingDebt(), 0, "outstanding debt should clear");
        assertEq(lbsc.totalActiveCollateral(), 0, "active collateral should clear");
        uint256 stableBalanceAfterUnwind = stableToken.balanceOf(alice);
        assertGt(stableBalanceAfterUnwind, stableBalanceAfterBuild, "collateral should return");
        assertLe(stableBalanceAfterUnwind, initialStableBalance, "collateral should not increase");
        assertFractionRemainingIsZero(address(shiva), positionId);
        assertOVLTokenBalanceIsZero(address(shiva));
        _assertNoOpenLbscLoans();
    }

    function test_unwind_stable_partialFractionReverts() public {
        vm.startPrank(alice);
        uint256 positionId = buildStablePosition(1_000e18, 2e18, BASIC_SLIPPAGE, true, 0);
        uint256 loanId = shiva.loanIds(ovlMarket, positionId);
        assertGt(loanId, 0, "LBSC loan should be tracked");

        uint256 priceLimit = Utils.getUnwindPrice(
            ovlState, ovlMarket, positionId, address(shiva), 5e17, BASIC_SLIPPAGE
        );
        vm.expectRevert("Shiva: unwind fraction must be 1 for lbsc");
        shiva.unwind(ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, 5e17, priceLimit));
        vm.stopPrank();
    }

    function test_unwind_stable_notOwner() public {
        vm.startPrank(alice);
        uint256 positionId = buildStablePosition(1_000e18, 2e18, BASIC_SLIPPAGE, true, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        shiva.unwind(ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, ONE, 0));
        vm.stopPrank();
    }

    function test_unwind_stable_pausedShiva() public {
        vm.startPrank(alice);
        uint256 positionId = buildStablePosition(1_000e18, 2e18, BASIC_SLIPPAGE, true, 0);
        vm.stopPrank();

        pauseShiva();

        vm.startPrank(alice);
        uint256 loanId = shiva.loanIds(ovlMarket, positionId);
        assertGt(loanId, 0, "LBSC loan should be tracked");
        uint256 priceLimit = Utils.getUnwindPrice(
            ovlState, ovlMarket, positionId, address(shiva), ONE, BASIC_SLIPPAGE
        );
        vm.expectRevert("Pausable: paused");
        shiva.unwind(ShivaStructs.Unwind(ovlMarket, BROKER_ID, positionId, ONE, priceLimit));
        vm.stopPrank();
    }

    function test_lbsc_openLoansMatchStableBalance() public {
        vm.startPrank(alice);
        buildStablePosition(2_000e18, 2e18, BASIC_SLIPPAGE, true, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        buildStablePosition(3_000e18, 3e18, BASIC_SLIPPAGE, false, 0);
        vm.stopPrank();

        _assertLbscCollateralAccounting(2);
    }

    function test_lbsc_noGhostLoansAfterSettle() public {
        vm.startPrank(alice);
        uint256 alicePosition = buildStablePosition(2_000e18, 2e18, BASIC_SLIPPAGE, true, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobPosition = buildStablePosition(1_500e18, 2e18, BASIC_SLIPPAGE, false, 0);
        vm.stopPrank();

        _assertLbscCollateralAccounting(2);

        vm.startPrank(alice);
        unwindPosition(alicePosition, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        vm.startPrank(bob);
        unwindPosition(bobPosition, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        _assertNoOpenLbscLoans();
    }

    function testFuzz_build_stable_unwind_profit(
        bool isLong,
        uint256 stableCollateral,
        uint256 leverage,
        uint256 priceImpactBps
    ) public {
        stableCollateral = bound(stableCollateral, 1_000e18, 50_000e18);
        leverage = bound(leverage, ONE, 5e18);
        priceImpactBps = bound(priceImpactBps, 20_000, 50_000); // 2x - 5x move

        uint256 aliceStableBefore = stableToken.balanceOf(alice);
        uint256 aliceOvlBefore = ovlToken.balanceOf(alice);

        vm.startPrank(alice);
        uint256 positionId =
            buildStablePosition(stableCollateral, leverage, BASIC_SLIPPAGE, isLong, 0);
        vm.stopPrank();

        _assertLbscCollateralAccounting(1);

        _setFavorablePrice(isLong, priceImpactBps);

        vm.startPrank(alice);
        unwindPosition(positionId, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        uint256 aliceStableAfter = stableToken.balanceOf(alice);
        uint256 aliceOvlAfter = ovlToken.balanceOf(alice);
        uint256 loanId = shiva.loanIds(ovlMarket, positionId);
        (, , , , bool settled) = lbsc.loans(loanId);

        assertTrue(settled, "loan should settle");
        assertEq(lbsc.totalOutstandingDebt(), 0, "debt should clear");
        assertEq(lbsc.totalActiveCollateral(), 0, "collateral should clear");
        assertEq(aliceStableAfter, aliceStableBefore, "collateral should return on profit");
        assertGt(aliceOvlAfter, aliceOvlBefore, "profit should return extra OVL");
        assertOVLTokenBalanceIsZero(address(shiva));
        _assertNoOpenLbscLoans();
    }

    function testFuzz_build_stable_unwind_loss(
        bool isLong,
        uint256 stableCollateral,
        uint256 leverage,
        uint256 priceImpactBps
    ) public {
        stableCollateral = bound(stableCollateral, 1_000e18, 50_000e18);
        leverage = bound(leverage, ONE, 2e18);
        priceImpactBps = bound(priceImpactBps, 11_500, 13_500); // 1.15x - 1.35x move

        uint256 aliceStableBefore = stableToken.balanceOf(alice);
        uint256 aliceOvlBefore = ovlToken.balanceOf(alice);

        vm.startPrank(alice);
        uint256 positionId =
            buildStablePosition(stableCollateral, leverage, BASIC_SLIPPAGE, isLong, 0);
        vm.stopPrank();

        _assertLbscCollateralAccounting(1);

        _setUnfavorablePrice(isLong, priceImpactBps);

        vm.startPrank(alice);
        unwindPosition(positionId, ONE, BASIC_SLIPPAGE);
        vm.stopPrank();

        uint256 aliceStableAfter = stableToken.balanceOf(alice);
        uint256 aliceOvlAfter = ovlToken.balanceOf(alice);
        uint256 loanId = shiva.loanIds(ovlMarket, positionId);
        (, , , , bool settled) = lbsc.loans(loanId);

        assertTrue(settled, "loan should settle");
        assertEq(lbsc.totalOutstandingDebt(), 0, "debt should clear");
        assertEq(lbsc.totalActiveCollateral(), 0, "collateral should clear");
        assertLt(aliceStableAfter, aliceStableBefore, "loss should seize collateral");
        assertLe(aliceOvlAfter, aliceOvlBefore, "loss should not mint extra OVL");
        assertOVLTokenBalanceIsZero(address(shiva));
        _assertNoOpenLbscLoans();
    }

    function _setFavorablePrice(bool isLong, uint256 priceImpactBps) internal {
        int256 basePrice = aggregator.latestAnswer();
        require(basePrice > 0, "invalid base price");
        int256 impact = int256(priceImpactBps);
        int256 newPrice =
            isLong ? (basePrice * impact) / int256(10_000) : (basePrice * int256(10_000)) / impact;
        _setMarketPrice(newPrice);
    }

    function _setUnfavorablePrice(bool isLong, uint256 priceImpactBps) internal {
        int256 basePrice = aggregator.latestAnswer();
        require(basePrice > 0, "invalid base price");
        int256 impact = int256(priceImpactBps);
        int256 newPrice =
            isLong ? (basePrice * int256(10_000)) / impact : (basePrice * impact) / int256(10_000);
        _setMarketPrice(newPrice);
    }

    function _setMarketPrice(int256 newPrice) internal {
        require(newPrice > 0, "price must be positive");
        uint256 nextRound = aggregator.latestRound() + 1;
        vm.startPrank(deployer);
        aggregator.submit(nextRound, newPrice);
        vm.warp(block.timestamp + 3600);
        aggregator.submit(nextRound + 1, newPrice);
        vm.stopPrank();
        vm.warp(block.timestamp + 3600);
    }

    function _assertLbscCollateralAccounting(uint256 expectedOpenLoans) internal view {
        (uint256 sumCollateral,, uint256 openLoans) = _getLbscOpenLoanStats();
        assertEq(openLoans, expectedOpenLoans, "unexpected open loan count");
        assertEq(sumCollateral, lbsc.totalActiveCollateral(), "active collateral mismatch");
        uint256 stableBalance = stableToken.balanceOf(address(lbsc));
        uint256 surplus = lbsc.availableStableSurplus();
        assertGe(stableBalance, surplus, "surplus exceeds balance");
        assertEq(sumCollateral, stableBalance - surplus, "stable balance mismatch");
    }

    function _assertNoOpenLbscLoans() internal view {
        (uint256 sumCollateral,, uint256 openLoans) = _getLbscOpenLoanStats();
        assertEq(openLoans, 0, "open loans remain");
        assertEq(sumCollateral, 0, "collateral locked unexpectedly");
        assertEq(lbsc.totalActiveCollateral(), 0, "LBSC collateral should be zero");
        uint256 stableBalance = stableToken.balanceOf(address(lbsc));
        uint256 surplus = lbsc.availableStableSurplus();
        assertGe(stableBalance, surplus, "surplus exceeds balance");
        assertEq(stableBalance - surplus, 0, "stable balance mismatch after settle");
    }

    function _getLbscOpenLoanStats()
        internal
        view
        returns (uint256 sumCollateral, uint256 sumDebt, uint256 openLoans)
    {
        uint256 nextLoanId = lbsc.nextLoanId();
        for (uint256 loanId = 1; loanId < nextLoanId; loanId++) {
            (address borrower, uint256 collateral, uint256 debt,, bool settled) = lbsc.loans(loanId);
            if (!settled) {
                require(borrower != address(0), "loan borrower zero");
                require(collateral > 0, "stableLocked must be > 0");
                sumCollateral += collateral;
                sumDebt += debt;
                openLoans++;
            }
        }
    }

    function test_setLbsc_onlyGovernor() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("Shiva: !governor"));
        shiva.setLbsc(address(lbsc));
        vm.stopPrank();
    }

    function test_setLbsc_zeroAddress() public {
        vm.startPrank(deployer);
        vm.expectRevert(bytes("Shiva: lbsc is zero"));
        shiva.setLbsc(address(0));
        vm.stopPrank();
    }
}
