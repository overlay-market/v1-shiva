// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Shiva} from "src/Shiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {LoanBasedStableCollateral} from "src/LoanBasedStableCollateral.sol";

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
