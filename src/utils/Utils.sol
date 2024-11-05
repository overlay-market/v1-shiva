// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";

/// @title Utils
/// @notice Utility functions for Overlay V1 to estimate prices and unwind positions
library Utils {
    uint256 private constant SLIPPAGE_SCALE = 100;

    /**
     * @notice Calculates the estimated price with slippage for a given market position.
     * @param ovState The overlay state contract instance.
     * @param ovMarket The overlay market contract instance.
     * @param collateral Amount of collateral used.
     * @param leverage Multiplier for the position leverage.
     * @param slippage Acceptable slippage, expressed in percentage (0 - 100).
     * @param isLong Boolean indicating if the position is long or short.
     * @return Estimated price after applying slippage.
     */
    function getEstimatedPrice(
        IOverlayV1State ovState,
        IOverlayV1Market ovMarket,
        uint256 collateral,
        uint256 leverage,
        uint8 slippage,
        bool isLong
    ) external view returns (uint256) {
        require(slippage <= SLIPPAGE_SCALE, "Shiva:slp>100");

        uint256 oiEstimated = ovState.oiEstimate(ovMarket, collateral, leverage, isLong);
        uint256 fractionOfCapOi = ovState.fractionOfCapOi(ovMarket, oiEstimated);

        // Calculate adjusted price based on slippage
        if (isLong) {
            unchecked {
                return ovState.ask(ovMarket, fractionOfCapOi) * (SLIPPAGE_SCALE + slippage)
                    / SLIPPAGE_SCALE;
            }
        } else {
            unchecked {
                return ovState.bid(ovMarket, fractionOfCapOi) * (SLIPPAGE_SCALE - slippage)
                    / SLIPPAGE_SCALE;
            }
        }
    }

    /**
     * @notice Calculates the unwind price for a given fraction of an open position.
     * @param ovState The overlay state contract instance.
     * @param ovMarket The overlay market contract instance.
     * @param positionId Identifier of the position to unwind.
     * @param owner Address of the position owner.
     * @param fraction Fraction of the position to unwind (1e18 represents 100%).
     * @param slippage Acceptable slippage, expressed in percentage (0 - 100).
     * @return Unwind price after applying slippage.
     */
    function getUnwindPrice(
        IOverlayV1State ovState,
        IOverlayV1Market ovMarket,
        uint256 positionId,
        address owner,
        uint256 fraction,
        uint8 slippage
    ) external view returns (uint256, bool) {
        require(slippage <= SLIPPAGE_SCALE, "Shiva:slp>100");

        // Fetch open interest shares for the position
        (,,,, bool isLong,,,) =
            ovMarket.positions(keccak256(abi.encodePacked(owner, positionId)));
        // uint256 oiSharesFraction = oiShares * fraction / 1e18;
        uint256 currentOi = ovState.oi(ovMarket, owner, positionId);
        uint256 fractionOfCapOi = ovState.fractionOfCapOi(ovMarket, currentOi * fraction / 1e18);

        // Calculate adjusted unwind price based on slippage
        if (!isLong) {
            unchecked {
                return (
                    ovState.ask(ovMarket, fractionOfCapOi) * (SLIPPAGE_SCALE + slippage)
                        / SLIPPAGE_SCALE,
                    isLong
                );
            }
        } else {
            unchecked {
                return (
                    ovState.bid(ovMarket, fractionOfCapOi) * (SLIPPAGE_SCALE - slippage)
                        / SLIPPAGE_SCALE,
                    isLong
                );
            }
        }
    }
}
