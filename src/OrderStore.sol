// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {ShivaStructs} from "./ShivaStructs.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOrderStore} from "./interfaces/shiva/IOrderStore.sol";
import {IShiva} from "./IShiva.sol";
import {IOverlayV1Token, GOVERNOR_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";

/**
 * @title OrderStore
 * @author Overlay team
 * @notice This contract is the on-chain source of truth for all advanced order requests.
 * @dev It stores and manages the state of OrderRequest structs.
 */
contract OrderStore is IOrderStore {
    using Counters for Counters.Counter;

    /// @notice The Overlay V1 Token contract, used for role-based access control.
    IOverlayV1Token public ovlToken;

    /// @notice The address of the Shiva contract, which is the only one authorized to create requests.
    IShiva public shiva;

    /// @notice The address of the KeeperHandler contract, authorized to update request statuses.
    address public keeperHandler;

    /// @notice A counter to generate unique request IDs.
    Counters.Counter private _requestIds;

    /// @notice Stores all advanced order requests, mapped by their unique ID.
    mapping(uint256 => ShivaStructs.OrderRequest) public requests;

    /**
     * @dev Ensures the caller is the main Shiva contract.
     */
    modifier onlyShiva() {
        if (msg.sender != address(shiva)) revert Unauthorized(msg.sender);
        _;
    }

    /**
     * @dev Ensures the caller is the registered KeeperHandler contract.
     */
    modifier onlyKeeperHandler() {
        if (msg.sender != keeperHandler) revert Unauthorized(msg.sender);
        _;
    }

    /**
     * @dev Ensures the caller has the governor role.
     */
    modifier onlyGovernor() {
        if (!ovlToken.hasRole(GOVERNOR_ROLE, msg.sender)) revert Unauthorized(msg.sender);
        _;
    }

    /**
     * @param _ovlToken The address of the OVL token for access control.
     * @param _shiva The address of the main Shiva contract.
     */
    constructor(address _ovlToken, address _shiva) {
        ovlToken = IOverlayV1Token(_ovlToken);
        shiva = IShiva(_shiva);
    }

    /**
     * @notice Sets or updates the address of the Shiva contract.
     * @dev Only callable by the governor.
     * @param _shiva The new address for the Shiva contract.
     */
    function setShiva(address _shiva) external onlyGovernor {
        shiva = IShiva(_shiva);
    }

    /**
     * @notice Sets or updates the address of the KeeperHandler contract.
     * @dev Only callable by the governor.
     * @param _keeperHandler The new address for the KeeperHandler.
     */
    function setKeeperHandler(address _keeperHandler) external onlyGovernor {
        keeperHandler = _keeperHandler;
        emit KeeperHandlerUpdated(_keeperHandler);
    }

    /**
     * @notice Creates a new advanced order request.
     * @dev This function can only be called by the Shiva contract.
     * @param params The parameters for creating the request, bundled in a struct.
     * @return requestId The unique ID of the newly created request.
     */
    function createRequest(
        ShivaStructs.CreateRequestParams calldata params
    ) external onlyShiva returns (uint256) {
        _requestIds.increment();
        uint256 requestId = _requestIds.current();

        requests[requestId] = ShivaStructs.OrderRequest({
            owner: params.owner,
            status: ShivaStructs.OrderStatus.PENDING,
            orderType: params.orderType,
            market: params.market,
            positionId: params.positionId,
            fraction: params.fraction,
            collateral: params.collateral,
            leverage: params.leverage,
            isLong: params.isLong,
            triggerPrice: params.triggerPrice,
            slippageToleranceBps: params.slippageToleranceBps,
            executionFee: params.executionFee
        });

        emit RequestCreated(requestId, params.owner, params.orderType);

        return requestId;
    }

    /**
     * @notice Updates the status of an existing order request.
     * @dev Can only be called by the KeeperHandler contract.
     * @param _requestId The ID of the request to update.
     * @param _status The new status for the order.
     */
    function updateRequestStatus(
        uint256 _requestId,
        ShivaStructs.OrderStatus _status
    ) external onlyKeeperHandler {
        requests[_requestId].status = _status;
        emit RequestStatusUpdated(_requestId, _status);
    }

    /**
     * @notice Retrieves an order request by its ID.
     * @param _requestId The ID of the request.
     * @return The OrderRequest struct.
     */
    function getRequest(
        uint256 _requestId
    ) external view returns (ShivaStructs.OrderRequest memory) {
        return requests[_requestId];
    }

    /**
     * @notice Returns the next request ID that will be assigned.
     * @dev This is equivalent to the total number of requests created.
     * @return The next request ID.
     */
    function nextRequestId() external view returns (uint256) {
        return _requestIds.current() + 1;
    }
} 