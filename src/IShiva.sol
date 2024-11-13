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
        ShivaStructs.Build memory params
    ) external returns (uint256 positionId);

    function build(
        ShivaStructs.BuildOnBehalfOf memory params
    ) external returns (uint256 positionId);

    function buildSingle(
        ShivaStructs.BuildSingle memory params
    ) external returns (uint256 positionId);

    function buildSingle(
        ShivaStructs.BuildSingleOnBehalfOf memory params
    ) external returns (uint256 positionId);

    function unwind(ShivaStructs.Unwind memory params) external;

    function unwind(ShivaStructs.UnwindOnBehalfOf memory params) external;
}
