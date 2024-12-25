pragma solidity ^0.8.10;

import {Properties} from "./Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Utils} from "../../src/utils/Utils.sol";
import {ShivaStructs} from "../../src/ShivaStructs.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {Constants} from "../utils/Constants.sol";
import {IFluxAggregator} from "../../src/interfaces/aggregator/IFluxAggregator.sol";
import {IOverlayV1ChainlinkFeed} from
    "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";

abstract contract TargetFunctions is BaseTargetFunctions, Properties {
    using ECDSA for bytes32;

    uint256[] public positionIds;

    function handler_build_and_unwind_position(
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        bool isLong,
        uint256 unwindFracture
    ) external {
        collateral = between(collateral, 0, 1e21);
        leverage = between(leverage, ONE, 1e20);
        slippage = uint16(between(uint256(slippage), 0, 10000));

        deal(address(ovToken), alice, collateral * 2);

        vm.startPrank(alice);
        uint256 posId = buildPosition(collateral, leverage, slippage, isLong);
        positionIds.push(posId);

        if (positionIds.length > 0 && slippage % 2 == 0) {
            uint256 randomPosIndex = between(slippage, 0, positionIds.length - 1);
            uint256 randomFraction;
            // Toggle between partial unwind and full unwind
            if (isLong) {
                randomFraction = between(unwindFracture, 0.1e18, ONE);
            } else {
                randomFraction = ONE;
            }
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

        uint256 randomPosIndex = between(slippage, 0, positionIds.length - 1);
        uint256 previousPosId = positionIds[randomPosIndex];

        deal(address(ovToken), alice, collateral * 2);
        vm.startPrank(alice);
        uint256 newPosId = buildSinglePosition(collateral, leverage, previousPosId, slippage);

        positionIds[randomPosIndex] = newPosId;
        vm.stopPrank();
    }

    function handler_liquidate_position(uint256 posIdIndex) external {
        if (positionIds.length == 0) return;

        posIdIndex = between(posIdIndex, 0, positionIds.length - 1);
        uint256 posId = positionIds[posIdIndex];

        // Get position info to check if long/short
        (,,,, bool isLong, bool liquidated,,) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));

        // Skip if already liquidated
        if (liquidated) return;

        // Get aggregator and current price
        IFluxAggregator aggregator =
            IFluxAggregator(IOverlayV1ChainlinkFeed(ovMarket.feed()).aggregator());
        address oracle = aggregator.getOracles()[0];
        int256 currentPrice = aggregator.latestAnswer();

        // Adjust price to trigger liquidation
        // For longs: price goes down (divide by 2)
        // For shorts: price goes up (multiply by 2)
        int256 newPrice = isLong ? currentPrice / 2 : currentPrice * 2;

        // Submit new price twice to confirm the round
        vm.startPrank(oracle);
        aggregator.submit(aggregator.latestRound() + 1, newPrice);
        vm.warp(block.timestamp + 60 * 60);
        aggregator.submit(aggregator.latestRound() + 1, newPrice);
        vm.stopPrank();

        if (ovState.liquidatable(ovMarket, address(shiva), posId)) {
            vm.prank(bob);
            ovMarket.liquidate(address(shiva), posId);

            // Remove liquidated position from array
            positionIds[posIdIndex] = positionIds[positionIds.length - 1];
            positionIds.pop();
        }
    }

    function handler_emergency_withdraw(uint256 posIdIndex) external {
        if (positionIds.length == 0) return;

        posIdIndex = between(posIdIndex, 0, positionIds.length - 1);
        uint256 posId = positionIds[posIdIndex];

        vm.prank(alice);
        shiva.emergencyWithdraw(ovMarket, posId, alice);

        positionIds[posIdIndex] = positionIds[positionIds.length - 1];
        positionIds.pop();
    }

    function handler_pause_unpause(bool shouldPause) external {
    function handler_pause_unpause() external {
        vm.prank(pauser);
        if (shiva.paused()) {
            shiva.unpause();
        } else {
            shiva.pause();
        }
    }

    function handler_add_remove_factory(address factory, bool shouldAdd) external {
        vm.startPrank(guardian);
        if (shouldAdd) {
            shiva.addFactory(IOverlayV1Factory(factory));
        } else {
            shiva.removeFactory(IOverlayV1Factory(factory));
        }
        vm.stopPrank();
    }

    function handler_build_with_signature(
        uint256 collateral,
        uint256 leverage,
        uint256 previousPositionId,
        uint16 slippage,
        uint48 deadline
    ) external {
        collateral = between(collateral, 0, 1e21);
        leverage = between(leverage, ONE, 1e20);
        slippage = uint16(between(uint256(slippage), 0, 10000));
        deadline = uint48(block.timestamp + 1 hours);

        bytes32 digest = getBuildSingleOnBehalfOfDigest(
            collateral, leverage, previousPositionId, shiva.nonces(alice), deadline
        );

        bytes memory signature = getSignature(digest, alicePk);

        deal(address(ovToken), alice, collateral * 2);
        uint256 posId = buildSinglePositionOnBehalfOf(
            collateral, leverage, previousPositionId, slippage, deadline, signature, alice
        );
        positionIds.push(posId);
    }

    function _calculateTotalNotionalRemaining() internal view override returns (uint256) {
        uint256 totalNotional;
        for (uint256 i = 0; i < positionIds.length; i++) {
            totalNotional += Utils.getNotionalRemaining(ovMarket, positionIds[i], address(shiva));
        }
        return totalNotional;
    }
}
