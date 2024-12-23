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
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = this.handler_build_and_unwind_position.selector;
        selectors[1] = this.handler_build_single_position.selector;
        selectors[2] = this.handler_liquidate_position.selector;
        selectors[3] = this.handler_emergency_withdraw.selector;
        selectors[4] = this.handler_pause_unpause.selector;
        selectors[5] = this.handler_add_remove_factory.selector;
        selectors[6] = this.handler_build_with_signature.selector;

        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    // uncomment this to run invariant test
    // to run only this test:  forge test --match-contract ShivaCryticToFoundry

    // function invariant_shiva_dont_have_ov() public {
    //     assertTrue(property_shiva_dont_have_ov());
    // }

    // function invariant_staking_balance_matches_notional() public {
    //     assertTrue(property_staking_balance_matches_notional());
    // }
}
