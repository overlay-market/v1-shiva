// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TargetFunctions} from "./TargetFunctions.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {Test} from "forge-std/Test.sol";

contract ShivaCryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public override {
        setup();

        vm.startPrank(alice);
        ovToken.approve(address(shiva), type(uint256).max);
        vm.stopPrank();

        // target the fuzzer on this contract as it will
        // contain the handler functions
        targetContract(address(this));

        // handler functions to target during invariant tests
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = this.handler_build_and_unwind_position.selector;

        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    // uncomment this to run invariant test
    // to run only this test:  forge test --match-contract ShivaCryticToFoundry

    // function invariant_shiva_dont_have_ov() public {
    //     assertTrue(property_shiva_dont_have_ov());
    // }
}
