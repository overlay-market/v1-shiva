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
}
