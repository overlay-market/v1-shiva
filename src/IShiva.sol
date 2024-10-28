// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IOverlayV1Market} from "./v1-core/IOverlayV1Market.sol";

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

    function ownerOf(
        IOverlayV1Market market,
        uint256 positionId
    ) external view returns (address);

    function build(
        IOverlayV1Market market,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) external returns (uint256 positionId);

    function buildOnBehalfOf(
        IOverlayV1Market market,
        address owner,
        bytes calldata signature,
        uint256 deadline,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) external returns (uint256 positionId);

    function unwind(
        IOverlayV1Market market,
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) external;

    function unwindOnBehalfOf(
        IOverlayV1Market market,
        address owner,
        bytes calldata signature,
        uint256 deadline,
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) external;
}
