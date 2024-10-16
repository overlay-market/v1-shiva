// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IOverlayV1Market {
    function build(
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 priceLimit
    ) external returns (uint256 positionId);

    function unwind(
        uint256 positionId,
        uint256 fraction,
        uint256 priceLimit
    ) external;

    function positions(bytes32 key)
        external
        view
        returns (
            uint96 notionalInitial,
            uint96 debtInitial,
            int24 midTick,
            int24 entryTick,
            bool isLong,
            bool liquidated,
            uint240 oiShares,
            uint16 fractionRemaining
        );

    // risk params
    function params(uint256 idx) external view returns (uint256);
}
