// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

/**
 * @title MarketImpersonator
 * @notice Contract to impersonate a market liquidation
 */
contract MarketImpersonator {
    uint96 notionalInitial;
    uint16 fractionRemaining;

    constructor() {}

    function impersonateLiquidation(
        address _shiva,
        uint256 _positionId,
        uint96 _notionalInitial
    ) external {
        notionalInitial = _notionalInitial;
        address(_shiva).call(
            abi.encodeWithSignature("overlayMarketLiquidateCallback(uint256)", _positionId)
        );
    }

    function positions(
        bytes32 key
    )
        external
        returns (
            uint96 notionalInitial_,
            uint96 debtInitial_,
            int24 midTick_,
            int24 entryTick_,
            bool isLong_,
            bool liquidated_,
            uint240 oiShares_,
            uint16 fractionRemaining_
        )
    {
        notionalInitial_ = notionalInitial;
        fractionRemaining_ = 1e4;
    }
}
