// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Asserts} from "@chimera/Asserts.sol";
import {BaseSetup} from "@chimera/BaseSetup.sol";
import {ShivaTestBase} from "../ShivaBase.t.sol";

abstract contract Properties is BaseSetup, ShivaTestBase, Asserts {
    // Makes sure that no OV token stays on Shiva contract
    function property_shiva_dont_have_ov() public view returns (bool result) {
        if (ovToken.balanceOf(address(shiva)) == 0) {
            result = true;
        }
    }

    function property_staking_balance_matches_notional() public view returns (bool result) {
        uint256 totalNotionalRemaining = _calculateTotalNotionalRemaining();
        uint256 stakingBalance = shiva.stakingToken().balanceOf(address(shiva.rewardVault()));

        if (stakingBalance == totalNotionalRemaining) {
            result = true;
        }
    }

    // Helper function to calculate total notional remaining
    // We are override this method in TargetFunctions to get access to positionIds
    function _calculateTotalNotionalRemaining() internal view virtual returns (uint256) {}
}
