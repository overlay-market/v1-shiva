// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Asserts} from "@chimera/Asserts.sol";
import {BaseSetup} from "@chimera/BaseSetup.sol";
import {ShivaTestBase} from "../ShivaBase.t.sol";

abstract contract Properties is BaseSetup, ShivaTestBase, Asserts {
    mapping(uint256 => address) public shPositionOwners;

    // Makes sure that no OV token stays on Shiva contract
    function property_shiva_dont_have_ov() public view returns (bool result) {
        if (ovToken.balanceOf(address(shiva)) == 0) {
            result = true;
        }
    }

    function property_staking_balance_matches_notional() public view returns (bool) {
        uint256 totalNotionalRemaining = _calculateTotalNotionalRemaining();
        uint256 stakingBalance = shiva.stakingToken().balanceOf(address(shiva.rewardVault()));

        return stakingBalance == totalNotionalRemaining;
    }

    function property_position_always_has_owner() public view returns (bool result) {
        result = true;

        uint256[] memory positionIds = _getPositionIds();
        for (uint256 i = 0; i < positionIds.length; i++) {
            if (shiva.positionOwners(ovMarket, positionIds[i]) == address(0)) {
                result = false;
            }
        }
    }

    function property_position_doesnt_change_owner() public view returns (bool result) {
        result = true;

        uint256[] memory positionIds = _getPositionIds();
        for (uint256 i = 0; i < positionIds.length; i++) {
            address shPositionOwner = shPositionOwners[positionIds[i]];
            address actualPositionOwner = shiva.positionOwners(ovMarket, positionIds[i]);

            if (shPositionOwner == address(0)) {
                shPositionOwner = actualPositionOwner;
            } else {
                if (actualPositionOwner != shPositionOwner) {
                    result = false;
                }
            }
        }
    }

    // Helper function to calculate total notional remaining
    // We are override this method in TargetFunctions to get access to positionIds
    function _calculateTotalNotionalRemaining() internal view virtual returns (uint256) {}

    // Getter for currently created position IDs
    function _getPositionIds() internal view virtual returns (uint256[] memory) {}
}
