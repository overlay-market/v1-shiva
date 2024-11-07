// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {ShivaStructs} from "./ShivaStructs.sol";

interface IShiva {
    event BuildSingle(
        address indexed owner,
        address market,
        uint256 previousPositionId,
        uint256 newPositionId,
        uint256 collateral,
        uint256 totalCollateral
    );

    error NotPositionOwner();
    error ExpiredDeadline();
    error InvalidSignature();

    function build(
        IOverlayV1Market market,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) external returns (uint256 positionId);

    function buildSingle(ShivaStructs.BuildSingle memory params)
        external
        returns (uint256 positionId);

    function buildOnBehalfOf(
        ShivaStructs.BuildOnBehalfOf memory params
    ) external returns (uint256 positionId);

    function unwind(
        IOverlayV1Market market,
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) external;

    function unwindOnBehalfOf(
        ShivaStructs.UnwindOnBehalfOf memory params
    ) external;
}
