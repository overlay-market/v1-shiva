// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";

library ShivaStructs {
    struct Build {
        IOverlayV1Market ovMarket;
        bool isLong;
        uint256 collateral;
        uint256 leverage;
        uint256 priceLimit;
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

    struct BuildSingle {
        IOverlayV1Market ovMarket;
        uint16 slippage;
        uint256 collateral;
        uint256 leverage;
        uint256 previousPositionId;
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

    struct Unwind {
        IOverlayV1Market ovMarket;
        uint256 positionId;
        uint256 fraction;
        uint256 priceLimit;
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
}
