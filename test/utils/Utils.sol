// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IOverlayV1State} from "../../src/v1-core/IOverlayV1State.sol";
import {IOverlayV1Market} from "../../src/v1-core/IOverlayV1Market.sol";

library Utils {
    function getEstimatedPrice(
        IOverlayV1State state,
        IOverlayV1Market market,
        uint256 collateral,
        uint256 leverage,
        uint256 slippage,
        bool isLong
    ) external view returns (uint256) {
        uint256 oiEstimated = state.oiEstimate(market, collateral, leverage, isLong);
        uint256 fractionOfCapOi = state.fractionOfCapOi(market, oiEstimated);

        if (isLong) {
            return state.ask(market, fractionOfCapOi) * (100 + slippage) / 100;
        } else {
            return state.bid(market, fractionOfCapOi) * (100 - slippage) / 100;
        }
    }
}