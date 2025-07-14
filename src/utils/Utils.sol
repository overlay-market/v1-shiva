// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {FixedCast} from "v1-core/contracts/libraries/FixedCast.sol";
import {IOverlayV1Feed} from "v1-core/contracts/interfaces/feeds/IOverlayV1Feed.sol";
import {Oracle} from "v1-core/contracts/libraries/Oracle.sol";

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
     * @param ovlState The overlay state contract instance.
     * @param ovlMarket The overlay market contract instance.
     * @param collateral Amount of collateral used.
     * @param leverage Multiplier for the position leverage.
     * @param slippage Acceptable slippage, expressed in percentage (0 - 100) with 2 decimal places.
     * @param isLong Boolean indicating if the position is long or short.
     * @return Estimated price after applying slippage.
     */
    function getEstimatedPrice(
        IOverlayV1State ovlState,
        IOverlayV1Market ovlMarket,
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        bool isLong
    ) external view returns (uint256) {
        require(slippage <= SLIPPAGE_SCALE, "Shiva:slp>10000");

        uint256 oiEstimated = ovlState.oiEstimate(ovlMarket, collateral, leverage, isLong);
        uint256 fractionOfCapOi = ovlState.fractionOfCapOi(ovlMarket, oiEstimated);

        // Calculate adjusted price based on slippage
        if (isLong) {
            unchecked {
                return ovlState.ask(ovlMarket, fractionOfCapOi) * (SLIPPAGE_SCALE + slippage)
                    / SLIPPAGE_SCALE;
            }
        } else {
            unchecked {
                return ovlState.bid(ovlMarket, fractionOfCapOi) * (SLIPPAGE_SCALE - slippage)
                    / SLIPPAGE_SCALE;
            }
        }
    }

    /**
     * @notice Calculates the unwind price for a given fraction of an open position.
     * @param ovlState The overlay state contract instance.
     * @param ovlMarket The overlay market contract instance.
     * @param positionId Identifier of the position to unwind.
     * @param owner Address of the position owner.
     * @param fraction Fraction of the position to unwind (ONE represents 100%).
     * @param slippage Acceptable slippage, expressed in percentage (0 - 100) with 2 decimal places.
     * @return Unwind price after applying slippage.
     */
    function getUnwindPrice(
        IOverlayV1State ovlState,
        IOverlayV1Market ovlMarket,
        uint256 positionId,
        address owner,
        uint256 fraction,
        uint16 slippage
    ) external view returns (uint256) {
        require(slippage <= SLIPPAGE_SCALE, "Shiva:slp>10000");

        // Fetch open interest shares for the position
        (,,,, bool isLong,,,) = ovlMarket.positions(keccak256(abi.encodePacked(owner, positionId)));
        uint256 currentOi = ovlState.oi(ovlMarket, owner, positionId);
        uint256 fractionOfCapOi = ovlState.fractionOfCapOi(ovlMarket, currentOi * fraction / ONE);

        // Calculate adjusted unwind price based on slippage
        if (!isLong) {
            unchecked {
                return ovlState.ask(ovlMarket, fractionOfCapOi) * (SLIPPAGE_SCALE + slippage)
                    / SLIPPAGE_SCALE;
            }
        } else {
            unchecked {
                return ovlState.bid(ovlMarket, fractionOfCapOi) * (SLIPPAGE_SCALE - slippage)
                    / SLIPPAGE_SCALE;
            }
        }
    }

    /**
     * @notice Calculates the notional remaining for a given position.
     * @param ovlMarket The overlay market contract instance.
     * @param positionId Identifier of the position to unwind.
     * @param owner Address of the position owner.
     * @return notionalRemaining Notional remaining for the position.
     */
    function getNotionalRemaining(
        IOverlayV1Market ovlMarket,
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
        ) = ovlMarket.positions(keccak256(abi.encodePacked(owner, positionId)));
        notionalRemaining = uint256(notionalInitial_).mulUp(fractionRemaining_.toUint256Fixed());
    }

    /**
     * @notice Fetches the position side (long or short) for a given position.
     * @param ovlMarket The overlay market contract instance.
     * @param positionId Identifier of the position.
     * @param owner Address of the position owner.
     * @return isLong Boolean indicating if the position is long.
     */
    function getPositionSide(
        IOverlayV1Market ovlMarket,
        uint256 positionId,
        address owner
    ) internal view returns (bool isLong) {
        (,,,, isLong,,,) = ovlMarket.positions(keccak256(abi.encodePacked(owner, positionId)));
    }

    /**
     * @notice Checks if the stop loss trigger condition is met for a position.
     * @param market The market interface.
     * @param positionId The ID of the position.
     * @param shivaAddress The address of the Shiva contract holding the position.
     * @param triggerPrice The trigger price for the stop loss.
     * @return True if the trigger condition is met, false otherwise.
     */
    function checkStopLossTrigger(
        IOverlayV1Market market,
        uint256 positionId,
        address shivaAddress,
        uint256 triggerPrice
    ) external view returns (bool) {
        bool isLong = getPositionSide(market, positionId, shivaAddress);

        IOverlayV1Feed feed = IOverlayV1Feed(market.feed());
        Oracle.Data memory data = feed.latest();

        // For stop-loss, we are unwinding a position.
        // For a long position, we sell, so we look at the bid price.
        // For a short position, we buy, so we look at the ask price.
        uint256 currentPrice = isLong ? market.bid(data, 0) : market.ask(data, 0);

        if (isLong) {
            // Trigger when the current price is less than or equal to the trigger price.
            return currentPrice <= triggerPrice;
        } else {
            // Trigger when the current price is greater than or equal to the trigger price.
            return currentPrice >= triggerPrice;
        }
    }

    /**
     * @notice Calculates the dynamic relayer fee based on gas consumed.
     * @param gasUsed The amount of gas consumed by the transaction.
     * @param nativeOvlFeed The oracle feed for the NATIVE/OVL price.
     * @param keeperIncentive The percentage premium to add to the fee (e.g., 1e16 for 1%).
     * @return The total fee in OVL.
     */
    function calculateDynamicRelayerFee(
        uint256 gasUsed,
        IOverlayV1Feed nativeOvlFeed,
        uint256 keeperIncentive
    ) internal view returns (uint256) {
        Oracle.Data memory data = nativeOvlFeed.latest();
        // Use the average of micro and macro window prices for stability
        uint256 nativeOvlPrice = (data.priceOverMicroWindow + data.priceOverMacroWindow) / 2;

        // nativeCost = gasUsed * tx.gasprice (wei)
        uint256 nativeCost = gasUsed * tx.gasprice;

        // ovlCost = (nativeCost * nativeOvlPrice) / 1e18
        uint256 ovlCost = nativeCost.mulUp(nativeOvlPrice);

        uint256 premiumAmount = ovlCost.mulUp(keeperIncentive);
        
        return ovlCost + premiumAmount;
    }
}
