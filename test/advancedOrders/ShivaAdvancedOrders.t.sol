// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {ShivaTestBase} from "../ShivaBase.t.sol";
import {OrderStore} from "src/OrderStore.sol";
import {OrderVault} from "src/OrderVault.sol";
import {KeeperHandler} from "src/KeeperHandler.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {IOrderStore} from "src/interfaces/shiva/IOrderStore.sol";
import {
    IBerachainRewardsVaultFactory
} from "src/interfaces/berachain/IRewardVaults.sol";
import {Shiva} from "src/Shiva.sol";
import {IShiva} from "src/IShiva.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ShivaAdvancedOrdersTest
 * @dev Full integration test suite for the advanced order functionality.
 */
contract ShivaAdvancedOrdersTest is ShivaTestBase {
    OrderStore public orderStore;
    OrderVault public orderVault;
    KeeperHandler public keeperHandler;

    uint256 public constant EXECUTION_FEE = 1e18; // 1 OVL
    uint256 public constant COLLATERAL = 1000e18;

    // Additional setup for advanced order tests
    function setUp() public override {
        super.setUp();

        // Deploy and set up the advanced order contracts
        vm.startPrank(deployer);
        orderStore = new OrderStore(address(ovlToken), address(shiva));
        orderVault = new OrderVault(address(ovlToken));
        keeperHandler = new KeeperHandler(
            address(ovlToken), address(shiva), address(orderStore), address(orderVault)
        );
        
        // Authorize Shiva to pull funds from the vault for execution
        orderVault.setAuthorizations(address(shiva), true);
        // Authorize KeeperHandler to pay keepers and update statuses
        orderVault.setAuthorizations(address(keeperHandler), true);
        orderStore.setKeeperHandler(address(keeperHandler));
        vm.stopPrank();

        // Alice approves the Shiva contract to spend her OVL for orders
        vm.startPrank(alice);
        ovlToken.approve(address(shiva), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Test the full lifecycle of a limit order: create, execute, and verify.
     */
    function test_create_and_execute_limit_order_happy_path() public {
        // 1. Create the limit order request
        uint256 aliceInitialBalance = ovlToken.balanceOf(alice);
        uint256 vaultInitialBalance = ovlToken.balanceOf(address(orderVault));
        uint256 nextRequestId = orderStore.nextRequestId();

        ShivaStructs.CreateLimitOrderParams memory params = ShivaStructs.CreateLimitOrderParams({
            market: ovlMarket,
            isLong: true,
            collateral: COLLATERAL,
            leverage: 2e18,
            triggerPrice: 1500e18, // Target price to buy
            slippageToleranceBps: 100, // 1%
            executionFee: EXECUTION_FEE
        });

        vm.startPrank(alice);
        uint256 requestId = shiva.createLimitOrder(params);
        vm.stopPrank();

        // Assert creation effects
        assertEq(
            ovlToken.balanceOf(alice),
            aliceInitialBalance - (COLLATERAL + EXECUTION_FEE),
            "Alice's balance should decrease by collateral + fee"
        );
        assertEq(
            ovlToken.balanceOf(address(orderVault)),
            vaultInitialBalance + (COLLATERAL + EXECUTION_FEE),
            "Vault balance should increase by collateral + fee"
        );
        assertEq(requestId, nextRequestId, "Request ID mismatch");

        // 2. Manipulate oracle price to meet the trigger condition
        // Price needs to be <= triggerPrice for a long limit order
        uint256 nextRoundId = aggregator.latestRound() + 1;
        aggregator.submit(nextRoundId, 1499e8); // Price is 1499 with 8 decimals
        vm.warp(block.timestamp + 3600); // Fast-forward 1 hour

        // 3. Execute the order as a keeper
        uint256 automatorInitialBalance = ovlToken.balanceOf(automator);

        vm.startPrank(automator);
        keeperHandler.executeOrder(requestId);
        vm.stopPrank();

        // 4. Verify post-execution state
        // Vault should have paid out collateral to Shiva (which then sends to market) and fee to keeper
        assertEq(
            ovlToken.balanceOf(address(orderVault)),
            vaultInitialBalance,
            "Vault should be empty after execution"
        );
        assertEq(
            ovlToken.balanceOf(automator),
            automatorInitialBalance + EXECUTION_FEE,
            "Automator should receive execution fee"
        );

        // Order status should be EXECUTED
        ShivaStructs.OrderRequest memory storedRequest = orderStore.getRequest(requestId);
        assertEq(
            uint256(storedRequest.status),
            uint256(ShivaStructs.OrderStatus.EXECUTED),
            "Status should be EXECUTED"
        );

        // A position should now exist for Alice
        // The positionId will be 1 as it's the first position created
        uint256 expectedPositionId = 1;
        assertEq(
            shiva.positionOwners(ovlMarket, expectedPositionId),
            alice,
            "Alice should be the owner of the new position"
        );
    }

    /**
     * @notice Test that a user can create and then cancel a limit order.
     */
    function test_create_and_cancel_limit_order() public {
        // 1. Create the limit order request
        vm.startPrank(alice);
        uint256 requestId = shiva.createLimitOrder(
            ShivaStructs.CreateLimitOrderParams({
                market: ovlMarket,
                isLong: true,
                collateral: COLLATERAL,
                leverage: 2e18,
                triggerPrice: 1500e18,
                slippageToleranceBps: 100,
                executionFee: EXECUTION_FEE
            })
        );
        vm.stopPrank();

        uint256 aliceBalanceAfterCreate = ovlToken.balanceOf(alice);
        uint256 vaultBalanceAfterCreate = ovlToken.balanceOf(address(orderVault));

        // 2. Cancel the order as Alice
        vm.startPrank(alice);
        shiva.cancelOrder(requestId);
        vm.stopPrank();

        // 3. Verify post-cancellation state
        // Alice should be refunded her collateral and execution fee
        assertEq(
            ovlToken.balanceOf(alice),
            aliceBalanceAfterCreate + COLLATERAL + EXECUTION_FEE,
            "Alice should be fully refunded"
        );
        assertEq(
            ovlToken.balanceOf(address(orderVault)),
            vaultBalanceAfterCreate - (COLLATERAL + EXECUTION_FEE),
            "Vault balance should decrease after refund"
        );

        // Order status should be CANCELLED
        ShivaStructs.OrderRequest memory storedRequest = orderStore.getRequest(requestId);
        assertEq(
            uint256(storedRequest.status),
            uint256(ShivaStructs.OrderStatus.CANCELLED),
            "Status should be CANCELLED"
        );

        // Attempting to cancel again should fail
        vm.startPrank(alice);
        bytes4 expectedError = IShiva.InvalidOrderStatus.selector;
        vm.expectRevert(
            abi.encodeWithSelector(
                expectedError,
                requestId,
                ShivaStructs.OrderStatus.CANCELLED,
                ShivaStructs.OrderStatus.PENDING
            )
        );
        shiva.cancelOrder(requestId);
        vm.stopPrank();
    }
} 