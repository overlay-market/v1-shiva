// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

/**
 * @title IKeeperHandler
 * @notice Interface for the KeeperHandler contract.
 * @dev This contract is the sole entry point for keepers to execute advanced orders.
 */
interface IKeeperHandler {
    /**
     * @notice Called by a keeper to attempt execution of a pending advanced order.
     * @dev This function will perform all necessary checks (status, trigger price)
     *      and, if valid, will call the main Shiva contract to perform the execution.
     * @param _requestId The unique ID of the order request to execute.
     */
    function executeOrder(uint256 _requestId) external;
} 