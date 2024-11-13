// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";

library ShivaStructs {
    struct BuildSingle {
        uint256 collateral;
        uint256 leverage;
        uint256 previousPositionId;
        IOverlayV1Market ovMarket;
        uint16 slippage;
    }

    struct BuildOnBehalfOf {
        IOverlayV1Market ovMarket;
        uint48 deadline;
        uint256 collateral;
        uint256 leverage;
        uint256 priceLimit;
        bytes signature;
        address owner;
        bool isLong;
    }

    struct UnwindOnBehalfOf {
        IOverlayV1Market ovMarket;
        uint48 deadline;
        uint256 positionId;
        uint256 fraction;
        uint256 priceLimit;
        bytes signature;
        address owner;
    }

    struct BuildSingleOnBehalfOf {
        IOverlayV1Market ovMarket;
        uint48 deadline;
        uint16 slippage;
        bool isLong;
        uint256 collateral;
        uint256 leverage;
        uint256 previousPositionId;
        bytes signature;
        address owner;
    }
}