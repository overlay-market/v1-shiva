// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";

interface IOverlayV1State {
    // bid on the market given new volume from fractionOfCapOi
    function bid(IOverlayV1Market market, uint256 fractionOfCapOi) external view returns (uint256 bid_);

    // ask on the market given new volume from fractionOfCapOi
    function ask(IOverlayV1Market market, uint256 fractionOfCapOi) external view returns (uint256 ask_);

    // mid on the market
    function mid(IOverlayV1Market market) external view returns (uint256 mid_);

    // estimated open interest of position on the market
    function oiEstimate(IOverlayV1Market market, uint256 collateral, uint256 leverage, bool isLong)
        external
        view
        returns (uint256 oi_);

    // fraction of cap on aggregate open interest given oi amount
    function fractionOfCapOi(IOverlayV1Market market, uint256 oi) external view returns (uint256 fractionOfCapOi_);
}
