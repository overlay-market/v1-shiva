// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

/**
 * @title IOrderVault
 * @notice Interface for the OrderVault contract.
 */
interface IOrderVault {
    /**
     * @notice Error thrown when a function is called by an unauthorized address.
     * @param caller The address that attempted the unauthorized call.
     */
    error Unauthorized(address caller);

    /**
     * @notice Transfers a specified amount of OVL to a recipient.
     * @dev This function is used for several purposes:
     *      - Paying a fee to a keeper for successful execution.
     *      - Refunding a user's collateral and fee upon cancellation.
     *      - Transferring collateral to the main Shiva contract for execution.
     *      Can only be called by an authorized contract (Shiva or KeeperHandler).
     * @param _to The recipient's address.
     * @param _amount The amount of OVL to transfer.
     */
    function pay(address _to, uint256 _amount) external;
} 