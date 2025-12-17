// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TargetFunctions} from "./TargetFunctions.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {Test} from "forge-std/Test.sol";

contract ShivaCryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public override {
        setup();

        vm.startPrank(alice);
        ovlToken.approve(address(shiva), type(uint256).max);
        vm.stopPrank();

        // target the fuzzer on this contract as it will
        // contain the handler functions
        targetContract(address(this));

        // handler functions to target during invariant tests
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.handler_build_and_unwind_position.selector;
        selectors[1] = this.handler_build_single_position.selector;
        selectors[2] = this.buildStable.selector;
        selectors[3] = this.handler_liquidate_position.selector;

        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    // uncomment this to run invariant test
    // to run only this test:  forge test --match-contract ShivaCryticToFoundry

    function invariant_shiva_dont_have_ov() public view {
        assertTrue(property_shiva_dont_have_ovl());
    }

    function invariant_lbsc_collateral_accounting() public view {
        assertTrue(property_lbsc_collateral_accounting());
    }

    function invariant_stable_builds_have_valid_loans() public view {
        assertTrue(property_stable_builds_have_valid_loans());
    }

    function invariant_no_residual_funds_after_settle() public view {
        assertTrue(property_no_residual_funds_after_settle());
    }

    // function invariant_staking_balance_matches_notional() public view {
    //     assertTrue(property_staking_balance_matches_notional());
    // }
}
