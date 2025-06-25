// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test} from "forge-std/Test.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {IShiva} from "src/IShiva.sol";

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
    }

    /**
     * @dev Group of tests for the relayer fee
     */

    /**
     * @dev Test that the governor can set the relayer fee
     */
    function test_setRelayerFee() public {
        uint256 newFee = 500; // 5% in BPS

        vm.startPrank(deployer);
        shiva.setRelayerFee(newFee);
        vm.stopPrank();

        assertEq(shiva.relayerFee(), newFee, "Relayer fee should be updated");
    }

    /**
     * @dev Test that a non-governor cannot set the relayer fee
     */
    function test_revert_setRelayerFee_not_governor() public {
        uint256 newFee = 500; // 5% in BPS

        vm.startPrank(alice);
        vm.expectRevert("Shiva: !governor");
        shiva.setRelayerFee(newFee);
        vm.stopPrank();
    }
} 