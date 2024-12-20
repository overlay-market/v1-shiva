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
     * @param ovMarket The market interface
     * @param brokerId The ID of the broker; 0 in most cases
     * @param isLong Indicates if the position is long
     * @param collateral The amount of collateral
     * @param leverage The leverage applied
     * @param priceLimit The price limit for the position
     */
    struct Build {
        IOverlayV1Market ovMarket;
        uint32 brokerId;
        bool isLong;
        uint256 collateral;
        uint256 leverage;
        uint256 priceLimit;
    }

    /**
     * @notice Represents the parameters to build a position through the Shiva contract
     * @param ovMarket The market interface
     * @param brokerId The ID of the broker; 0 in most cases
     * @param unwindPriceLimit The price limit for the unwind
     * @param buildPriceLimit The price limit for the position
     * @param collateral The amount of collateral
     * @param leverage The leverage applied
     * @param previousPositionId The ID of the previous position
     */
    struct BuildSingle {
        IOverlayV1Market ovMarket;
        uint32 brokerId;
        uint256 unwindPriceLimit;
        uint256 buildPriceLimit;
        uint256 collateral;
        uint256 leverage;
        uint256 previousPositionId;
    }

    /**
     * @notice Represents the parameters to unwind a position through the Shiva contract
     * @param ovMarket The market interface
     * @param brokerId The ID of the broker; 0 in most cases
     * @param positionId The ID of the position to unwind
     * @param fraction The fraction of the position to unwind
     * @param priceLimit The price limit for the unwind
     */
    struct Unwind {
        IOverlayV1Market ovMarket;
        uint32 brokerId;
        uint256 positionId;
        uint256 fraction;
        uint256 priceLimit;
    }

    /**
     * @notice Represents the parameters to perform operations on behalf of an owner
     * @param owner The address of the owner
     * @param deadline The deadline for the action
     * @param signature The signature of the owner
     */
    struct OnBehalfOf {
        address owner;
        uint48 deadline;
        bytes signature;
    }
}
