// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {ShivaTestBase} from "../ShivaBase.t.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {IOrderStore} from "src/interfaces/shiva/IOrderStore.sol";
import {OrderStore} from "src/OrderStore.sol";

/**
 * @title OrderStoreTest
 * @dev Test suite for the OrderStore contract.
 */
contract OrderStoreTest is ShivaTestBase {
    OrderStore public orderStore;

    // Additional setup for OrderStore tests
    function setUp() public override {
        super.setUp();

        // Deploy OrderStore and link it to the Shiva contract
        vm.startPrank(deployer);
        orderStore = new OrderStore(address(ovlToken), address(shiva));
        orderStore.setShiva(address(shiva));
        orderStore.setKeeperHandler(automator);
        vm.stopPrank();
    }

    /**
     * @notice Test that a request can be created successfully.
     * @dev This is the happy path test for request creation.
     */
    function test_create_request_happy_path() public {
        // Mock parameters for a LIMIT_OPEN order
        ShivaStructs.CreateRequestParams memory params = ShivaStructs.CreateRequestParams({
            owner: alice,
            orderType: ShivaStructs.OrderType.LIMIT_OPEN,
            market: ovlMarket,
            positionId: 0,
            fraction: 0,
            collateral: 1000e18,
            leverage: 2e18,
            isLong: true,
            triggerPrice: 10000e18,
            slippageToleranceBps: 100, // 1%
            executionFee: 1e18
        });

        uint256 nextRequestId = orderStore.nextRequestId();

        // Prank as the Shiva contract to call the authorized function
        vm.startPrank(address(shiva));
        uint256 requestId = orderStore.createRequest(params);
        vm.stopPrank();

        // Assert that the request ID is correct
        assertEq(requestId, nextRequestId, "Request ID mismatch");
        assertEq(orderStore.nextRequestId(), nextRequestId + 1, "Next request ID did not increment");

        // Retrieve the stored request and verify its properties
        ShivaStructs.OrderRequest memory storedRequest = orderStore.getRequest(requestId);

        assertEq(storedRequest.owner, params.owner, "Owner mismatch");
        assertEq(
            uint256(storedRequest.status),
            uint256(ShivaStructs.OrderStatus.PENDING),
            "Status should be PENDING"
        );
        assertEq(
            uint256(storedRequest.orderType),
            uint256(params.orderType),
            "OrderType mismatch"
        );
        assertEq(address(storedRequest.market), address(params.market), "Market mismatch");
        assertEq(storedRequest.collateral, params.collateral, "Collateral mismatch");
        assertEq(storedRequest.leverage, params.leverage, "Leverage mismatch");
        assertEq(storedRequest.isLong, params.isLong, "isLong mismatch");
        assertEq(storedRequest.triggerPrice, params.triggerPrice, "TriggerPrice mismatch");
        assertEq(
            storedRequest.slippageToleranceBps,
            params.slippageToleranceBps,
            "Slippage mismatch"
        );
        assertEq(storedRequest.executionFee, params.executionFee, "ExecutionFee mismatch");
    }

    /**
     * @notice Test that creating a request reverts if the caller is not Shiva.
     */
    function test_create_request_revert_unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderStore.Unauthorized.selector, address(this)));

        // Attempt to call from an unauthorized address (this test contract)
        orderStore.createRequest(
            ShivaStructs.CreateRequestParams({
                owner: alice,
                orderType: ShivaStructs.OrderType.LIMIT_OPEN,
                market: ovlMarket,
                positionId: 0,
                collateral: 1000e18,
                leverage: 2e18,
                isLong: true,
                fraction: 0,
                triggerPrice: 10000e18,
                slippageToleranceBps: 100,
                executionFee: 1e18
            })
        );
    }

    /**
     * @notice Test that the status of a request can be updated successfully.
     */
    function test_update_request_status_happy_path() public {
        // Step 1: Create a request first
        vm.startPrank(address(shiva));
        uint256 requestId = orderStore.createRequest(
            ShivaStructs.CreateRequestParams({
                owner: alice,
                orderType: ShivaStructs.OrderType.LIMIT_OPEN,
                market: ovlMarket,
                positionId: 0,
                collateral: 1000e18,
                leverage: 2e18,
                isLong: true,
                fraction: 0,
                triggerPrice: 10000e18,
                slippageToleranceBps: 100,
                executionFee: 1e18
            })
        );
        vm.stopPrank();

        // Step 2: Update the status as the authorized keeper
        vm.startPrank(automator);
        orderStore.updateRequestStatus(requestId, ShivaStructs.OrderStatus.EXECUTED);
        vm.stopPrank();

        // Step 3: Verify the new status
        ShivaStructs.OrderRequest memory storedRequest = orderStore.getRequest(requestId);
        assertEq(
            uint256(storedRequest.status),
            uint256(ShivaStructs.OrderStatus.EXECUTED),
            "Status should be EXECUTED"
        );
    }

    /**
     * @notice Test that updating a request status reverts if the caller is not the keeper handler.
     */
    function test_update_request_status_revert_unauthorized() public {
        // Step 1: Create a request first
        vm.startPrank(address(shiva));
        uint256 requestId = orderStore.createRequest(
            ShivaStructs.CreateRequestParams({
                owner: alice,
                orderType: ShivaStructs.OrderType.LIMIT_OPEN,
                market: ovlMarket,
                positionId: 0,
                collateral: 1000e18,
                leverage: 2e18,
                isLong: true,
                fraction: 0,
                triggerPrice: 10000e18,
                slippageToleranceBps: 100,
                executionFee: 1e18
            })
        );
        vm.stopPrank();

        // Step 2: Attempt to update from an unauthorized address
        vm.expectRevert(abi.encodeWithSelector(IOrderStore.Unauthorized.selector, address(this)));
        orderStore.updateRequestStatus(requestId, ShivaStructs.OrderStatus.EXECUTED);
    }
} 