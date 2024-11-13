// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Shiva} from "src/Shiva.sol";
import {IOverlayV1Market} from "v1-periphery/lib/v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {Constants} from "./utils/Constants.sol";
import {Utils} from "src/utils/Utils.sol";
import {OverlayV1Factory} from "v1-periphery/lib/v1-core/contracts/OverlayV1Factory.sol";
import {OverlayV1Token} from "v1-periphery/lib/v1-core/contracts/OverlayV1Token.sol";
import {Risk} from "v1-periphery/lib/v1-core/contracts/libraries/Risk.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";

contract ShivaTestBase is Test {
    using ECDSA for bytes32;

    uint256 constant ONE = 1e18;
    uint16 constant BASIC_SLIPPAGE = 100; // 1%

    Shiva shiva;
    IOverlayV1Market ovMarket;
    IOverlayV1State ovState;
    IERC20 ovToken;

    address alice;
    address bob;
    address charlie;
    address automator;

    uint256 alicePk = 0x123;
    uint256 bobPk = 0x456;
    uint256 charliePk = 0x789;    

   function setUp() public virtual {
        vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()), 92984086);

        ovToken = IERC20(Constants.getOVTokenAddress());
        ovMarket = IOverlayV1Market(Constants.getETHDominanceMarketAddress());
        ovState = IOverlayV1State(Constants.getOVStateAddress());

        shiva = new Shiva(address(ovToken), address(ovState));

        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        charlie = vm.addr(charliePk);
        automator = makeAddr("automator");

        labelAddresses();
        setInitialBalancesAndApprovals();
    }

    function labelAddresses() internal {
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(address(ovMarket), "Market");
        vm.label(address(shiva), "Shiva");
        vm.label(address(ovToken), "OVL");
    }

    function setInitialBalancesAndApprovals() internal {
        // Deal tokens and set approvals
        deal(address(ovToken), alice, 1000e18);
        deal(address(ovToken), bob, 1000e18);
        approveToken(alice);
        approveToken(bob);
    }

    function approveToken(address user) internal {
        vm.prank(user);
        ovToken.approve(address(shiva), type(uint256).max);
    }

    /**
     * Utility functions
     */

    function buildPosition(
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        bool isLong
    ) public returns (uint256) {
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, collateral, leverage, slippage, isLong);
        return shiva.build(
            ShivaStructs.Build(ovMarket, isLong, collateral, leverage, priceLimit)
        );
    }

    function unwindPosition(uint256 posId, uint256 fraction, uint16 slippage) public {
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), fraction, slippage);
        shiva.unwind(
            ShivaStructs.Unwind(ovMarket, posId, fraction, priceLimit)
        );
    }

    function buildSinglePosition(
        uint256 collateral,
        uint256 leverage,
        uint256 posId1,
        uint16 slippage
    ) public returns (uint256) {
        return shiva.buildSingle(
            ShivaStructs.BuildSingle(ovMarket, slippage, collateral, leverage, posId1)
        );
    }

    /**
     * Assertion functions
     */

    function assertFractionRemainingIsZero(address user, uint256 posId) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertEq(fractionRemaining, 0);
    }

    function assertFractionRemainingIsGreaterThanZero(address user, uint256 posId) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertGt(fractionRemaining, 0);
    }

    function assertFractionRemaining(address user, uint256 posId, uint16 expected) public view {
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(user, posId)));
        assertEq(fractionRemaining, expected);
    }

    function assertOVTokenBalanceIsZero(address user) public view {
        assertEq(ovToken.balanceOf(user), 0);
    }

    function assertUserIsPositionOwnerInShiva(address user, uint256 posId) public view {
        assertEq(shiva.positionOwners(ovMarket, posId), user);
    }
}