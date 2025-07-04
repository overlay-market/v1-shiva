// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";

/**
 * @title ShivaStructs
 * @notice Contains structs used by the Shiva contract
 */
library ShivaStructs {
    /**
     * @notice Represents the parameters to build a position through the Shiva contract
     * @param ovlMarket The market interface
     * @param brokerId The ID of the broker; 0 in most cases
     * @param isLong Indicates if the position is long
     * @param collateral The amount of collateral
     * @param leverage The leverage applied
     * @param priceLimit The price limit for the position
     */
    struct Build {
        IOverlayV1Market ovlMarket;
        uint32 brokerId;
        bool isLong;
        uint256 collateral;
        uint256 leverage;
        uint256 priceLimit;
    }

    /**
     * @notice Represents the parameters to build a position through the Shiva contract
     * @param ovlMarket The market interface
     * @param brokerId The ID of the broker; 0 in most cases
     * @param unwindPriceLimit The price limit for the unwind
     * @param buildPriceLimit The price limit for the position
     * @param collateral The amount of collateral
     * @param leverage The leverage applied
     * @param previousPositionId The ID of the previous position
     */
    struct BuildSingle {
        IOverlayV1Market ovlMarket;
        uint32 brokerId;
        uint256 unwindPriceLimit;
        uint256 buildPriceLimit;
        uint256 collateral;
        uint256 leverage;
        uint256 previousPositionId;
    }

    /**
     * @notice Represents the parameters to unwind a position through the Shiva contract
     * @param ovlMarket The market interface
     * @param brokerId The ID of the broker; 0 in most cases
     * @param positionId The ID of the position to unwind
     * @param fraction The fraction of the position to unwind
     * @param priceLimit The price limit for the unwind
     */
    struct Unwind {
        IOverlayV1Market ovlMarket;
        uint32 brokerId;
        uint256 positionId;
        uint256 fraction;
        uint256 priceLimit;
    }

    /**
     * @notice Represents the parameters to perform operations on behalf of an owner
     * @param owner The address of the owner
     * @param deadline The deadline for the action
     * @param nonce The nonce used in the signature
     * @param signature The signature of the owner
     */
    struct OnBehalfOf {
        address owner;
        uint48 deadline;
        uint256 nonce;
        bytes signature;
    }

    /**
     * @notice The type of advanced order.
     * @dev LIMIT_OPEN to open a new position at a target price.
     * @dev STOP_LOSS to close an existing position to limit losses.
     * @dev TAKE_PROFIT to close an existing position to secure gains.
     */
    enum OrderType {
        LIMIT_OPEN,
        STOP_LOSS,
        TAKE_PROFIT
    }

    /**
     * @notice The status of an advanced order request.
     * @dev PENDING when the order is created and waiting for execution.
     * @dev EXECUTED when the order has been successfully processed by a keeper.
     * @dev CANCELLED when the user has cancelled the order before execution.
     */
    enum OrderStatus {
        PENDING,
        EXECUTED,
        CANCELLED
    }

    /**
     * @notice Represents a request for an advanced order in the asynchronous system.
     * @param owner The user who created and owns the order request.
     * @param status The current status of the order (Pending, Executed, Cancelled).
     * @param orderType The type of order (Limit, StopLoss, TakeProfit).
     * @param market The market in which the order will be executed.
     * @param positionId The ID of the existing position for StopLoss/TakeProfit orders.
     * @param collateral The collateral for a LimitOpen order.
     * @param leverage The leverage for a LimitOpen order.
     * @param isLong The side (long/short) for a LimitOpen order.
     * @param fraction The portion of an existing position to close for SL/TP orders.
     * @param triggerPrice The price at which the order becomes executable.
     * @param slippageToleranceBps The acceptable slippage in basis points from the trigger price.
     * @param executionFee The fee paid by the user to the keeper for executing the order.
     */
    struct OrderRequest {
        address owner;
        OrderStatus status;
        OrderType orderType;
        IOverlayV1Market market;
        // Parameters for Stop-Loss / Take-Profit
        uint256 positionId;
        uint256 fraction;
        // Parameters for Limit Orders
        uint256 collateral;
        uint256 leverage;
        bool isLong;
        // Common parameters
        uint256 triggerPrice;
        uint256 slippageToleranceBps;
        uint256 executionFee;
    }

    /**
     * @notice Represents the parameters to create a new limit order request.
     * @param market The market in which the order will be executed.
     * @param isLong The side (long/short) for the limit order.
     * @param collateral The collateral for the limit order.
     * @param leverage The leverage for the limit order.
     * @param triggerPrice The price at which the order becomes executable.
     * @param slippageToleranceBps The acceptable slippage in basis points from the trigger price.
     * @param executionFee The fee paid by the user to the keeper for executing the order.
     */
    struct CreateLimitOrderParams {
        IOverlayV1Market market;
        bool isLong;
        uint256 collateral;
        uint256 leverage;
        uint256 triggerPrice;
        uint256 slippageToleranceBps;
        uint256 executionFee;
    }

    /**
     * @notice Represents the parameters to create a new stop-loss order request.
     * @param market The market of the position to close.
     * @param positionId The ID of the existing position to close.
     * @param fraction The portion of the position to close.
     * @param triggerPrice The price at which the order becomes executable.
     * @param slippageToleranceBps The acceptable slippage in basis points from the trigger price.
     * @param executionFee The fee paid by the user to the keeper for executing the order.
     */
    struct CreateStopLossOrderParams {
        IOverlayV1Market market;
        uint256 positionId;
        uint256 fraction;
        uint256 triggerPrice;
        uint256 slippageToleranceBps;
        uint256 executionFee;
    }

    /**
     * @notice Represents the parameters to create a new take-profit order request.
     * @param market The market of the position to close.
     * @param positionId The ID of the existing position to close.
     * @param fraction The portion of the position to close.
     * @param triggerPrice The price at which the order becomes executable.
     * @param slippageToleranceBps The acceptable slippage in basis points from the trigger price.
     * @param executionFee The fee paid by the user to the keeper for executing the order.
     */
    struct CreateTakeProfitOrderParams {
        IOverlayV1Market market;
        uint256 positionId;
        uint256 fraction;
        uint256 triggerPrice;
        uint256 slippageToleranceBps;
        uint256 executionFee;
    }

    /**
     * @notice Represents the parameters to create a new order request in the OrderStore.
     * @dev This struct is used to pass all necessary data to the `createRequest` function,
     *      avoiding "stack too deep" errors.
     * @param owner The user who is creating the order request.
     * @param orderType The type of order (Limit, StopLoss, TakeProfit).
     * @param market The market for the order.
     * @param positionId The ID of an existing position (for SL/TP orders).
     * @param collateral The collateral for a LimitOpen order.
     * @param leverage The leverage for a LimitOpen order.
     * @param isLong The side (long/short) for a LimitOpen order.
     * @param fraction The portion of a position to close (for SL/TP orders).
     * @param triggerPrice The price at which the order should be executed.
     * @param slippageToleranceBps Acceptable slippage in basis points.
     * @param executionFee The fee paid to the keeper.
     */
    struct CreateRequestParams {
        address owner;
        OrderType orderType;
        IOverlayV1Market market;
        uint256 positionId;
        uint256 collateral;
        uint256 leverage;
        bool isLong;
        uint256 fraction;
        uint256 triggerPrice;
        uint256 slippageToleranceBps;
        uint256 executionFee;
    }
}
