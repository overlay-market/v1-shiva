pragma solidity ^0.8.10;

import {Properties} from "./Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Utils} from "../../src/utils/Utils.sol";

abstract contract TargetFunctions is BaseTargetFunctions, Properties {
    uint256[] public positionIds;
    uint256[] public stablePositionIds;

    function handler_build_and_unwind_position(
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        uint8 isLong,
        uint256 unwindFracture
    ) external {
        collateral = between(collateral, 0, 1e21);
        leverage = between(leverage, ONE, 1e20);
        slippage = uint16(between(uint256(slippage), 0, 10000));
        isLong = uint8(between(uint256(isLong), 0, 1));

        deal(address(ovlToken), alice, collateral * 2);

        vm.startPrank(alice);
        uint256 posId = buildPosition(collateral, leverage, slippage, isLong != 0);
        positionIds.push(posId);

        // Randomly unwind some positions
        uint256 randomValue = slippage;
        if (positionIds.length > 0 && randomValue % 2 == 0) {
            uint256 randomPosIndex = between(randomValue, 0, positionIds.length - 1);
            uint256 randomFraction = between(unwindFracture, 0.1e18, ONE);
            unwindPosition(positionIds[randomPosIndex], randomFraction, slippage);
        }
        vm.stopPrank();
    }

    function handler_build_single_position(
        uint256 collateral,
        uint256 leverage,
        uint16 slippage
    ) external {
        if (positionIds.length == 0) return;

        collateral = between(collateral, 0, 1e21);
        leverage = between(leverage, ONE, 1e20);
        slippage = uint16(between(uint256(slippage), 0, 10000));

        uint256 randomValue = slippage;
        uint256 randomPosIndex = between(randomValue, 0, positionIds.length - 1);
        uint256 previousPosId = positionIds[randomPosIndex];

        deal(address(ovlToken), alice, collateral * 2);
        vm.startPrank(alice);

        uint256 unwindPriceLimit = Utils.getUnwindPrice(
            ovlState, ovlMarket, previousPosId, address(shiva), ONE, BASIC_SLIPPAGE
        );
        uint256 buildPriceLimit =
            Utils.getEstimatedPrice(ovlState, ovlMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        uint256 newPosId = buildSinglePosition(
            collateral, leverage, previousPosId, unwindPriceLimit, buildPriceLimit
        );

        positionIds[randomPosIndex] = newPosId;
        vm.stopPrank();
    }

    function buildStable(
        uint256 stableCollateral,
        uint256 leverage,
        uint16 slippage,
        uint8 isLong
    ) external {
        stableCollateral = between(stableCollateral, 1e18, 1e21);
        leverage = between(leverage, ONE, 1e20);
        slippage = uint16(between(uint256(slippage), 0, 10000));
        bool longPosition = isLong != 0;

        deal(address(stableToken), alice, stableCollateral * 2);

        vm.startPrank(alice);
        uint256 positionId =
            buildStablePosition(stableCollateral, leverage, slippage, longPosition, 0);
        stablePositionIds.push(positionId);

        uint256 randomValue = slippage;
        if (stablePositionIds.length > 0 && randomValue % 2 == 0) {
            uint256 randomPosIndex = between(randomValue, 0, stablePositionIds.length - 1);
            uint256 posIdToUnwind = stablePositionIds[randomPosIndex];
            unwindPosition(posIdToUnwind, ONE, slippage);

            // remove the unwound position
            stablePositionIds[randomPosIndex] =
                stablePositionIds[stablePositionIds.length - 1];
            stablePositionIds.pop();
        }

        vm.stopPrank();
    }

    function handler_liquidate_position(uint256 rnd, uint8 preferStable) external {
        uint256 normalCount = positionIds.length;
        uint256 stableCount = stablePositionIds.length;
        if (normalCount == 0 && stableCount == 0) return;

        bool useStable = preferStable % 2 == 0;
        if (stableCount == 0) useStable = false;
        if (normalCount == 0) useStable = true;

        uint256 index = useStable ? between(rnd, 0, stableCount - 1) : between(rnd, 0, normalCount - 1);
        uint256 posId = useStable ? stablePositionIds[index] : positionIds[index];

        if (!_ensureLiquidatable(posId)) return;

        vm.prank(bob);
        ovlMarket.liquidate(address(shiva), posId);

        _removeTrackedPosition(useStable, index);
    }

    function _ensureLiquidatable(uint256 posId) internal returns (bool) {
        if (ovlState.liquidatable(ovlMarket, address(shiva), posId)) {
            return true;
        }

        (,,,, bool isLong,,,) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        _forcePriceMove(isLong);

        return ovlState.liquidatable(ovlMarket, address(shiva), posId);
    }

    function _forcePriceMove(bool isLong) internal {
        int256 newPrice = isLong ? int256(1e8) : aggregator.latestAnswer() * 50;
        if (newPrice <= 0) newPrice = int256(1e8);
        if (newPrice > int256(1000000e8)) {
            newPrice = int256(1000000e8);
        }

        uint256 nextRound = aggregator.latestRound() + 1;
        vm.startPrank(deployer);
        aggregator.submit(nextRound, newPrice);
        vm.warp(block.timestamp + 1 hours);
        aggregator.submit(nextRound + 1, newPrice);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
    }

    function _removeTrackedPosition(bool isStable, uint256 index) internal {
        if (isStable) {
            uint256 lastIndex = stablePositionIds.length - 1;
            stablePositionIds[index] = stablePositionIds[lastIndex];
            stablePositionIds.pop();
        } else {
            uint256 lastIndex = positionIds.length - 1;
            positionIds[index] = positionIds[lastIndex];
            positionIds.pop();
        }
    }

    function _calculateTotalNotionalRemaining() internal view override returns (uint256) {
        uint256 totalNotional;

        for (uint256 i = 0; i < positionIds.length; i++) {
            totalNotional += Utils.getNotionalRemaining(ovlMarket, positionIds[i], address(shiva));
        }

        for (uint256 i = 0; i < stablePositionIds.length; i++) {
            totalNotional +=
                Utils.getNotionalRemaining(ovlMarket, stablePositionIds[i], address(shiva));
        }

        return totalNotional;
    }

    function _trackedPositionCount() internal view override returns (uint256) {
        return positionIds.length;
    }

    function _trackedStablePositionCount() internal view override returns (uint256) {
        return stablePositionIds.length;
    }

    function _hasStablePositionTracking() internal pure override returns (bool) {
        return true;
    }

    function _trackedStablePositionId(uint256 index) internal view override returns (uint256) {
        return stablePositionIds[index];
    }
}
