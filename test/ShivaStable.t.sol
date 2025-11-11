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
