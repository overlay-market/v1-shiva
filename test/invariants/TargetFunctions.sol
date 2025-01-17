pragma solidity ^0.8.10;

import {Properties} from "./Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Utils} from "../../src/utils/Utils.sol";

abstract contract TargetFunctions is BaseTargetFunctions, Properties {
    uint256[] public positionIds;

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

    function _calculateTotalNotionalRemaining() internal view override returns (uint256) {
        uint256 totalNotional;

        for (uint256 i = 0; i < positionIds.length; i++) {
            totalNotional += Utils.getNotionalRemaining(ovlMarket, positionIds[i], address(shiva));
        }

        return totalNotional;
    }
}
