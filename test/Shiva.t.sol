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
import {Utils} from "src/utils/Utils.sol";

contract ShivaTest is Test {
    using MessageHashUtils for bytes32;

    Shiva shiva;
    IOverlayV1Market ovMarket;
    IOverlayV1State ovState;
    IERC20 ovToken;

    uint256 alicePk = 0x123;
    address alice = vm.addr(alicePk);
    uint256 bobPk = 0x456;
    address bob = vm.addr(bobPk);
    uint256 charliePk = 0x789;
    address charlie = vm.addr(charliePk);
    address automator = makeAddr("automator");
    
    function setUp() public {
        vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()));

        ovToken = IERC20(Constants.getOVTokenAddress());
        ovMarket = IOverlayV1Market(Constants.getETHDominanceMarketAddress());
        ovState = IOverlayV1State(Constants.getOVStateAddress());

        shiva = new Shiva(address(ovToken), address(ovState));

        // Deal tokens to alice and bob (on the forked network)
        deal(address(ovToken), alice, 1000e18);
        deal(address(ovToken), bob, 1000e18);

        // Label the addresses for clarity in the test output
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(address(ovMarket), "Market");
        vm.label(address(shiva), "Shiva");
        vm.label(address(ovToken), "OVL");

        // Alice and Bob approve the Shiva contract to spend their OVL tokens
        vm.prank(alice);
        ovToken.approve(address(shiva), type(uint256).max);
        vm.prank(bob);
        ovToken.approve(address(shiva), type(uint256).max);
    }

    // Utility function to get price limit and build a position
    function buildPosition(uint256 collateral, uint256 leverage, uint8 slippage, bool isLong) public returns (uint256) {
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, collateral, leverage, slippage, isLong);
        return shiva.build(ovMarket, collateral, leverage, isLong, priceLimit);
    }

    // Utility function to unwind a position
    function unwindPosition(uint256 posId, uint256 fraction, uint8 slippage, bool isLong) public {
        uint256 priceLimit = Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), fraction, slippage, isLong);
        shiva.unwind(ovMarket, posId, fraction, priceLimit);
    }

    // Build method tests

    // Alice builds a position through Shiva
    function test_build() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);
        
        // the position is not associated with Alice in the ovMarket
        (,,,,,,,uint16 fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(alice, posId)));
        assertEq(fractionRemaining, 0);

        // the position is associated with Shiva in the ovMarket
        (,,,,,,,fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0);

        // the position is associated with Alice in Shiva
        assertEq(shiva.ownerOf(ovMarket, posId), alice);
    }

    // Build leverage less than minimum
    function test_build_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, 1e18, 1e18, 1, true);
        vm.expectRevert();
        shiva.build(ovMarket, 1e18, 1e18 - 1, true, priceLimit);
    }

    // Build fail not enough allowance
    function test_build_notEnoughAllowance() public {
        deal(address(ovToken), charlie, 1000e18);
        vm.startPrank(charlie);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, 1e18, 1e18, 1, true);
        vm.expectRevert();
        shiva.build(ovMarket, 1e18, 1e18, true, priceLimit);
    }

    // Build fail enough allowance but not enough balance considering the trading fee
    function test_build_notEnoughBalance() public {
        deal(address(ovToken), charlie, 1e18);
        vm.startPrank(charlie);
        ovToken.approve(address(shiva), type(uint256).max);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, 1e18, 1e18, 1, true);
        vm.expectRevert();
        shiva.build(ovMarket, 1e18, 1e18, true, priceLimit);
    }

    // Unwind method tests

    // Alice builds a position and then unwinds it through Shiva
    function test_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, 1e18, 1, true);

        // the position is successfully unwound
        (,,,,,,,uint16 fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);
    }

    function test_partial_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);

        // Alice unwinds 50% of her position through Shiva
        unwindPosition(posId, 5e17, 1, true);

        // the position is successfully unwound
        (,,,,,,,uint16 fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 5000);

        // The position is still associated with Alice in Shiva
        assertEq(shiva.ownerOf(ovMarket, posId), alice);
    }

    function test_unwind_notOwner(bool isLong) public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, isLong);
        vm.stopPrank();
        // Bob tries to unwind Alice's position through Shiva
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, 1e18, 1e18, 1, !isLong);
        vm.startPrank(bob);
        vm.expectRevert();
        shiva.unwind(ovMarket, posId, 1e18, priceLimit);
    }

    // BuildSingle method tests
    
    // Alice builds a position through Shiva and then builds another one
    function test_buildSingle() public {
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(1e18, 1e18, 1, true);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        uint256 posId2 = shiva.buildSingle(ovMarket, 1e18, 1e18, true, 1, posId1);

        // the first position is successfully unwound
        (,,,,,,,uint16 fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId1)));
        assertEq(fractionRemaining, 0);

        // the second position is associated with Alice in Shiva
        assertEq(shiva.ownerOf(ovMarket, posId2), alice);

        // the second position is not associated with Alice in the ovMarket
        (,,,,,,,fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(alice, posId2)));
        assertEq(fractionRemaining, 0);
    }

    // BuildSingle fail previous position not owned by the caller
    function test_buildSingle_noPreviousPosition() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shiva.buildSingle(ovMarket, 1e18, 1e18, true, 1, 1);
    }

    // BuildSingle fail leverage less than minimum
    function test_buildSingle_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);
        vm.expectRevert();
        shiva.buildSingle(ovMarket, 1e18, 1e18 - 1, true, 1, posId);
    }

    // BuildSingle fail slippage greater than 100
    function test_buildSingle_slippageGreaterThan100() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(1e18, 1e18, 1, true);
        vm.expectRevert();
        shiva.buildSingle(ovMarket, 1e18, 1e18, true, 101, posId);
    }

    // function test_buildOnBehalfOf_ownership(bool isLong) public {
    //     uint256 deadline = block.timestamp;
    //     uint256 collateral = 10e18;
    //     uint256 leverage = 1e18;
    //     uint256 priceLimit = isLong ? type(uint256).max : 0;

    //     // TODO: use EIP712 and add random nonces that can be nullified by the owner

    //     bytes32 msgHash = keccak256(abi.encodePacked(
    //         ovMarket,
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
    //     uint256 posId = shiva.buildOnBehalfOf(ovMarket, alice, signature, deadline, collateral, leverage, isLong, priceLimit);

    //     // the position is associated with Shiva in the ovMarket
    //     (,,,,,,,uint16 fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
    //     assertGt(fractionRemaining, 0);

    //     // the position is associated with Alice in Shiva
    //     assertEq(shiva.ownerOf(ovMarket, posId), alice);
    // }

    // function test_unwindOnBehalfOf_notOwner(bool isLong) public {
    //     // Alice builds a position through Shiva
    //     vm.prank(alice);
    //     uint256 posId = shiva.build(
    //         ovMarket, 10e18, 1e18, isLong, isLong ? type(uint256).max : 0
    //     );

    //     // TODO: use EIP712 and add random nonces that can be nullified by the owner

    //     // Bob makes a signature to try to unwind Alice's position through Shiva
    //     uint256 deadline = block.timestamp;
    //     uint256 fraction = 1e18;
    //     uint256 priceLimit = isLong ? 0 : type(uint256).max;
    //     bytes32 msgHash = keccak256(abi.encodePacked(
    //         ovMarket,
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
    //     shiva.unwindOnBehalfOf(ovMarket, bob, signature, deadline, posId, fraction, priceLimit);
    // }
}
