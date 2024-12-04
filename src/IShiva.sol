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
    error MarketNotValid();

    function build(
        ShivaStructs.Build calldata params
    ) external returns (uint256 positionId);

    function build(
        ShivaStructs.Build calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256 positionId);

    function buildSingle(
        ShivaStructs.BuildSingle calldata params
    ) external returns (uint256 positionId);

    function buildSingle(
        ShivaStructs.BuildSingle calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external returns (uint256 positionId);

    function unwind(
        ShivaStructs.Unwind calldata params
    ) external;

    function unwind(
        ShivaStructs.Unwind calldata params,
        ShivaStructs.OnBehalfOf calldata onBehalfOf
    ) external;

    function emergencyWithdraw(
        IOverlayV1Market market,
        uint256 positionId,
        address owner
    ) external;
}
