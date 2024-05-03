// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IShiva} from "src/IShiva.sol";
import {IOverlayV1Market} from "src/IOverlayV1Market.sol";

contract ShivaTest is Test {
    IShiva shiva;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    
    IOverlayV1Market market;
    IERC20 ovl;

    function setUp() public {
        // TODO: deploy Shiva and market contracts
        ovl = new ERC20Mock();
        deal(address(ovl), alice, 1_000_000e18);
        deal(address(ovl), bob, 1_000_000e18);
    }

    function test_build_ownership(bool isLong) public {
        // Alice builds a position through Shiva
        vm.prank(alice);
        uint256 posId = shiva.build({
            market: market,
            collateral: 10e18,
            leverage: 1e18,
            isLong: isLong,
            priceLimit: isLong ? type(uint256).max : 0
        });
        
        // the position is not associated with Alice in the market
        (,,,,,,,uint16 fractionRemaining) = market.positions(keccak256(abi.encodePacked(alice, posId)));
        assertEq(fractionRemaining, 0);

        // the position is associated with Shiva in the market
        (,,,,,,,fractionRemaining) = market.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0);

        // the position is associated with Alice in Shiva
        assertEq(shiva.ownerOf(market, posId), alice);
    }

    function test_unwind_notOwner(bool isLong) public {
        // Alice builds a position through Shiva
        vm.prank(alice);
        uint256 posId = shiva.build(
            market, 10e18, 1e18, isLong, isLong ? type(uint256).max : 0
        );

        // Bob tries to unwind Alice's position through Shiva
        vm.prank(bob);
        vm.expectRevert(IShiva.NotPositionOwner.selector);
        shiva.unwind(market, posId, 1e18, isLong ? 0 : type(uint256).max);
    }

    function test_unwind_successful(bool isLong) public {
        vm.startPrank(alice);

        // Alice builds a position through Shiva
        uint256 posId = shiva.build(
            market, 10e18, 1e18, isLong, isLong ? type(uint256).max : 0
        );

        // Alice unwinds her position through Shiva
        shiva.unwind(market, posId, 1e18, isLong ? 0 : type(uint256).max);

        // the position is successfully unwound
        (,,,,,,,uint16 fractionRemaining) = market.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);
    }
}
