// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {FixedCast} from "v1-core/contracts/libraries/FixedCast.sol";

/**
 * @title Utils
 * @notice Utility functions for Overlay V1 to estimate prices and unwind positions
 */
library Utils {
    using FixedPoint for uint256;
    using FixedCast for uint16;

    /// @dev Slippage scale set to 10000 to allow for 2 decimal places e.g. 1% = 100; 0.80% = 80
    uint256 private constant SLIPPAGE_SCALE = 10000;
    uint256 internal constant ONE = 1e18;

    /**
     * @notice Calculates the estimated price with slippage for a given market position.
     * @param ovState The overlay state contract instance.
     * @param ovMarket The overlay market contract instance.
     * @param collateral Amount of collateral used.
     * @param leverage Multiplier for the position leverage.
     * @param slippage Acceptable slippage, expressed in percentage (0 - 100) with 2 decimal places.
     * @param isLong Boolean indicating if the position is long or short.
     * @return Estimated price after applying slippage.
     */
    function getEstimatedPrice(
        IOverlayV1State ovState,
        IOverlayV1Market ovMarket,
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        bool isLong
    ) external view returns (uint256) {
        require(slippage <= SLIPPAGE_SCALE, "Shiva:slp>10000");

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
     * @param fraction Fraction of the position to unwind (ONE represents 100%).
     * @param slippage Acceptable slippage, expressed in percentage (0 - 100) with 2 decimal places.
     * @return Unwind price after applying slippage.
     */
    function getUnwindPrice(
        IOverlayV1State ovState,
        IOverlayV1Market ovMarket,
        uint256 positionId,
        address owner,
        uint256 fraction,
        uint16 slippage
    ) external view returns (uint256) {
        require(slippage <= SLIPPAGE_SCALE, "Shiva:slp>10000");

        // Fetch open interest shares for the position
        (,,,, bool isLong,,,) = ovMarket.positions(keccak256(abi.encodePacked(owner, positionId)));
        uint256 currentOi = ovState.oi(ovMarket, owner, positionId);
        uint256 fractionOfCapOi = ovState.fractionOfCapOi(ovMarket, currentOi * fraction / ONE);

        // Calculate adjusted unwind price based on slippage
        if (!isLong) {
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
     * @notice Calculates the notional remaining for a given position.
     * @param ovMarket The overlay market contract instance.
     * @param positionId Identifier of the position to unwind.
     * @param owner Address of the position owner.
     * @return notionalRemaining Notional remaining for the position.
     */
    function getNotionalRemaining(
        IOverlayV1Market ovMarket,
        uint256 positionId,
        address owner
    ) external view returns (uint256 notionalRemaining) {
        (
            uint96 notionalInitial_,
            , // uint96 debtInitial_,
            , // int24 midTick_,
            , // int24 entryTick_,
            , // bool isLong_,
            , // bool liquidated_,
            , // uint240 oiShares_,
            uint16 fractionRemaining_
        ) = ovMarket.positions(keccak256(abi.encodePacked(owner, positionId)));
        notionalRemaining = uint256(notionalInitial_).mulUp(fractionRemaining_.toUint256Fixed());
    }

    /**
     * @notice Fetches the position side (long or short) for a given position.
     * @param ovMarket The overlay market contract instance.
     * @param positionId Identifier of the position.
     * @param owner Address of the position owner.
     * @return isLong Boolean indicating if the position is long.
     */
    function getPositionSide(IOverlayV1Market ovMarket, uint256 positionId, address owner)
        external
        view
        returns (bool isLong)
    {
        (,,,, isLong,,,) = ovMarket.positions(keccak256(abi.encodePacked(owner, positionId)));
    }
}
