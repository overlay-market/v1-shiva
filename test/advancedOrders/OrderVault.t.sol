// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {ShivaTestBase} from "../ShivaBase.t.sol";
import {IOrderVault} from "src/interfaces/shiva/IOrderVault.sol";
import {OrderVault} from "src/OrderVault.sol";

/**
 * @title OrderVaultTest
 * @dev Test suite for the OrderVault contract.
 */
contract OrderVaultTest is ShivaTestBase {
    OrderVault public orderVault;
    uint256 public constant EXECUTION_FEE = 1e18; // 1 OVL

    // Additional setup for OrderVault tests
    function setUp() public override {
        super.setUp();

        // Deploy OrderVault and set permissions
        vm.startPrank(deployer);
        orderVault = new OrderVault(address(ovlToken));
        // Authorize automator (as keeper handler) to make payments
        orderVault.setAuthorizations(automator, true);
        vm.stopPrank();
    }

    /**
     * @notice Helper function to fund the vault for tests.
     */
    function _fundVault() internal {
        vm.startPrank(alice);
        ovlToken.transfer(address(orderVault), EXECUTION_FEE);
        vm.stopPrank();
    }

    /**
     * @notice Test that a keeper can be paid successfully.
     */
    function test_pay_keeper_happy_path() public {
        _fundVault();

        uint256 vaultBalance = ovlToken.balanceOf(address(orderVault));
        uint256 automatorBalance = ovlToken.balanceOf(automator);

        // Pay the keeper as the authorized automator
        vm.startPrank(automator);
        orderVault.pay(automator, EXECUTION_FEE);
        vm.stopPrank();

        assertEq(
            ovlToken.balanceOf(address(orderVault)),
            vaultBalance - EXECUTION_FEE,
            "Vault balance should decrease"
        );
        assertEq(
            ovlToken.balanceOf(automator),
            automatorBalance + EXECUTION_FEE,
            "Automator balance should increase"
        );
    }

    /**
     * @notice Test that paying a keeper reverts if the caller is not authorized.
     */
    function test_pay_keeper_revert_unauthorized() public {
        _fundVault();

        vm.expectRevert(abi.encodeWithSelector(IOrderVault.Unauthorized.selector, bob));
        // Attempt to pay from an unauthorized address (bob)
        vm.startPrank(bob);
        orderVault.pay(automator, EXECUTION_FEE);
        vm.stopPrank();
    }

    /**
     * @notice Test that a user can be refunded successfully.
     */
    function test_refund_user_happy_path() public {
        _fundVault();

        uint256 vaultBalance = ovlToken.balanceOf(address(orderVault));
        // In the new flow, Alice's balance doesn't change when funding the vault for the test
        uint256 aliceBalance = ovlToken.balanceOf(alice);

        // Refund the user as the authorized automator
        vm.startPrank(automator);
        orderVault.pay(alice, EXECUTION_FEE);
        vm.stopPrank();

        assertEq(
            ovlToken.balanceOf(address(orderVault)),
            vaultBalance - EXECUTION_FEE,
            "Vault balance should decrease"
        );
        assertEq(
            ovlToken.balanceOf(alice),
            aliceBalance + EXECUTION_FEE,
            "Alice's balance should increase after refund"
        );
    }
} 