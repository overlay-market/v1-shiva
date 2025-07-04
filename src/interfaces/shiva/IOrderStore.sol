// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {ShivaStructs} from "../../ShivaStructs.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";

/**
 * @title IOrderStore
 * @notice Interface for the OrderStore contract.
 */
interface IOrderStore {
    /**
     * @notice Emitted when a new advanced order request is created.
     * @param requestId The unique ID of the new request.
     * @param owner The user who initiated the request.
     * @param orderType The type of the order (Limit, StopLoss, TakeProfit).
     */
    event RequestCreated(
        uint256 indexed requestId, address indexed owner, ShivaStructs.OrderType orderType
    );

    /**
     * @notice Emitted when the status of an existing order request is updated.
     * @param requestId The unique ID of the request being updated.
     * @param newStatus The new status of the order.
     */
    event RequestStatusUpdated(uint256 indexed requestId, ShivaStructs.OrderStatus newStatus);

    /**
     * @notice Emitted when the KeeperHandler address is updated.
     * @param newKeeperHandler The new address of the KeeperHandler contract.
     */
    event KeeperHandlerUpdated(address indexed newKeeperHandler);

    /**
     * @notice Error thrown when a function is called by an unauthorized address.
     * @param caller The address that attempted the unauthorized call.
     */
    error Unauthorized(address caller);

    /**
     * @notice Creates a new advanced order request.
     * @dev This function can only be called by the main Shiva contract.
     *      It stores the request and assigns it a unique ID.
     * @param params The parameters for creating the request, bundled in a struct
     *      to avoid "stack too deep" errors.
     * @return The unique ID of the newly created request.
     */
    function createRequest(
        ShivaStructs.CreateRequestParams calldata params
    ) external returns (uint256);

    /**
     * @notice Updates the status of an existing order request.
     * @dev Can only be called by the authorized KeeperHandler contract.
     * @param _requestId The ID of the request to update.
     * @param _status The new status for the order (e.g., EXECUTED, CANCELLED).
     */
    function updateRequestStatus(
        uint256 _requestId,
        ShivaStructs.OrderStatus _status
    ) external;

    /**
     * @notice Retrieves the full data of an order request by its ID.
     * @param _requestId The ID of the request to retrieve.
     * @return A struct containing all the data for the requested order.
     */
    function getRequest(
        uint256 _requestId
    ) external view returns (ShivaStructs.OrderRequest memory);
} 