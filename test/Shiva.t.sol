// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Shiva} from "src/Shiva.sol";
import {IOverlayV1Market} from "src/v1-core/IOverlayV1Market.sol";
import {IOverlayV1State} from "src/v1-core/IOverlayV1State.sol";
import {Constants} from "./utils/Constants.sol";
import {Utils} from "./utils/Utils.sol";

contract ShivaTest is Test {
    using MessageHashUtils for bytes32;

    Shiva shiva;
    IOverlayV1Market market;
    IOverlayV1State state;
    IERC20 ovl;

    uint256 alicePk = 0x123;
    address alice = vm.addr(alicePk);
    uint256 bobPk = 0x456;
    address bob = vm.addr(bobPk);
    address automator = makeAddr("automator");
    
    function setUp() public {
        vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()));

        address ovlTokenAddress = Constants.getOVTokenAddress();
        console.log("OVL Token Address:", ovlTokenAddress);

        ovl = IERC20(Constants.getOVTokenAddress());
        market = IOverlayV1Market(Constants.getETHDominanceMarketAddress());
        state = IOverlayV1State(Constants.getOVStateAddress());

        shiva = new Shiva(address(ovl));

        // Deal tokens to alice and bob (on the forked network)
        deal(address(ovl), alice, 1000e18);
        deal(address(ovl), bob, 1000e18);

        // Label the addresses for clarity in the test output
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(address(market), "Market");
        vm.label(address(shiva), "Shiva");
        vm.label(address(ovl), "OVL");

        // Alice and Bob approve the Shiva contract to spend their OVL tokens
        vm.prank(alice);
        ovl.approve(address(shiva), type(uint256).max);
        vm.prank(bob);
        ovl.approve(address(shiva), type(uint256).max);
    }

    // Utility function to get price limit and build a position
    function buildPosition(uint256 collateral, uint256 leverage, uint256 slippage, bool isLong) public returns (uint256) {
        uint256 priceLimit = Utils.getEstimatedPrice(state, market, collateral, leverage, slippage, isLong);
        return shiva.build(market, collateral, leverage, isLong, priceLimit);
    }

    // Utility function to unwind a position
    function unwindPosition(uint256 posId, uint256 fraction, bool isLong) public {
        uint256 priceLimit = Utils.getEstimatedPrice(state, market, 1e18, 1e18, 1, !isLong);
        shiva.unwind(market, posId, fraction, priceLimit);
    }

    // Alice builds a position through Shiva
    function test_build() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);
        
        // the position is not associated with Alice in the market
        (,,,,,,,uint16 fractionRemaining) = market.positions(keccak256(abi.encodePacked(alice, posId)));
        assertEq(fractionRemaining, 0);

        // the position is associated with Shiva in the market
        (,,,,,,,fractionRemaining) = market.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0);

        // the position is associated with Alice in Shiva
        assertEq(shiva.ownerOf(market, posId), alice);
    }

    // Alice builds a position and then unwinds it through Shiva
    function test_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, 1e18, true);

        // the position is not associated with Alice in the market
        assertEq(shiva.ownerOf(market, posId), address(0));

        // the position is successfully unwound
        (,,,,,,,uint16 fractionRemaining) = market.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);
    }

    function test_partial_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);

        // Alice unwinds 50% of her position through Shiva
        unwindPosition(posId, 5e17, true);

        // the position is successfully unwound
        (,,,,,,,uint16 fractionRemaining) = market.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 5000);

        // The position is still associated with Alice in Shiva
        assertEq(shiva.ownerOf(market, posId), alice);
    }

    function test_unwind_notOwner(bool isLong) public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, isLong);
        vm.stopPrank();
        // Bob tries to unwind Alice's position through Shiva
        uint256 priceLimit = Utils.getEstimatedPrice(state, market, 1e18, 1e18, 1, !isLong);
        vm.startPrank(bob);
        vm.expectRevert();
        shiva.unwind(market, posId, 1e18, priceLimit);
    }

    // function test_buildOnBehalfOf_ownership(bool isLong) public {
    //     uint256 deadline = block.timestamp;
    //     uint256 collateral = 10e18;
    //     uint256 leverage = 1e18;
    //     uint256 priceLimit = isLong ? type(uint256).max : 0;

    //     // TODO: use EIP712 and add random nonces that can be nullified by the owner

    //     bytes32 msgHash = keccak256(abi.encodePacked(
    //         market,
    //         block.chainid,
    //         deadline,
    //         collateral,
    //         leverage,
    //         isLong,
    //         priceLimit
    //     )).toEthSignedMessageHash();

    //     bytes memory signature;
    //     {   // avoid stack too deep error
    //         (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, msgHash);
    //         signature = abi.encodePacked(r, s, v);
    //     }

    //     // the automator builds a position on behalf of Alice through Shiva
    //     vm.prank(automator);
    //     uint256 posId = shiva.buildOnBehalfOf(market, alice, signature, deadline, collateral, leverage, isLong, priceLimit);

    //     // the position is associated with Shiva in the market
    //     (,,,,,,,uint16 fractionRemaining) = market.positions(keccak256(abi.encodePacked(address(shiva), posId)));
    //     assertGt(fractionRemaining, 0);

    //     // the position is associated with Alice in Shiva
    //     assertEq(shiva.ownerOf(market, posId), alice);
    // }

    // function test_unwindOnBehalfOf_notOwner(bool isLong) public {
    //     // Alice builds a position through Shiva
    //     vm.prank(alice);
    //     uint256 posId = shiva.build(
    //         market, 10e18, 1e18, isLong, isLong ? type(uint256).max : 0
    //     );

    //     // TODO: use EIP712 and add random nonces that can be nullified by the owner

    //     // Bob makes a signature to try to unwind Alice's position through Shiva
    //     uint256 deadline = block.timestamp;
    //     uint256 fraction = 1e18;
    //     uint256 priceLimit = isLong ? 0 : type(uint256).max;
    //     bytes32 msgHash = keccak256(abi.encodePacked(
    //         market,
    //         block.chainid,
    //         deadline,
    //         posId,
    //         fraction,
    //         priceLimit
    //     )).toEthSignedMessageHash();
    //     bytes memory signature;
    //     {   // avoid stack too deep error
    //         (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, msgHash);
    //         signature = abi.encodePacked(r, s, v);
    //     }

    //     vm.prank(bob);
    //     vm.expectRevert(Shiva.NotPositionOwner.selector);
    //     shiva.unwindOnBehalfOf(market, bob, signature, deadline, posId, fraction, priceLimit);
    // }
}
