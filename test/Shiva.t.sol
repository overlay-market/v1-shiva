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
import {Position} from "v1-periphery/lib/v1-core/contracts/libraries/Position.sol";
import {IBerachainRewardsVault, IBerachainRewardsVaultFactory} from "../src/interfaces/berachain/IRewardVaults.sol";
import {FixedPoint} from "v1-periphery/lib/v1-core/contracts/libraries/FixedPoint.sol";

contract ShivaTest is Test {
    using ECDSA for bytes32;
    using FixedPoint for uint256;

    uint256 constant ONE = 1e18;
    uint16 constant BASIC_SLIPPAGE = 100; // 1%

    Shiva shiva;
    IOverlayV1Market ovMarket;
    IOverlayV1State ovState;
    IERC20 ovToken;
    IBerachainRewardsVault public rewardVault;

    uint256 alicePk = 0x123;
    address alice = vm.addr(alicePk);
    uint256 bobPk = 0x456;
    address bob = vm.addr(bobPk);
    uint256 charliePk = 0x789;
    address charlie = vm.addr(charliePk);
    address automator = makeAddr("automator");

    function setUp() public {
        vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()), Constants.getForkBlock());

        ovToken = IERC20(Constants.getOVTokenAddress());
        ovMarket = IOverlayV1Market(Constants.getETHDominanceMarketAddress());
        ovState = IOverlayV1State(Constants.getOVStateAddress());

        IBerachainRewardsVaultFactory vaultFactory = IBerachainRewardsVaultFactory(
            0x2B6e40f65D82A0cB98795bC7587a71bfa49fBB2B
        );
        shiva = new Shiva(address(ovToken), address(ovState), address(vaultFactory));
        rewardVault = shiva.rewardVault();

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
    function buildPosition(
        uint256 collateral,
        uint256 leverage,
        uint16 slippage,
        bool isLong
    ) public returns (uint256) {
        uint256 priceLimit =
            Utils.getEstimatedPrice(ovState, ovMarket, collateral, leverage, slippage, isLong);
        return shiva.build(ovMarket, collateral, leverage, isLong, priceLimit);
    }

    // Utility function to unwind a position
    function unwindPosition(uint256 posId, uint256 fraction, uint16 slippage) public {
        (uint256 priceLimit,) =
            Utils.getUnwindPrice(ovState, ovMarket, posId, address(shiva), fraction, slippage);
        shiva.unwind(ovMarket, posId, fraction, priceLimit);
    }

    // Build method tests

    // Alice builds a position through Shiva
    function test_build() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // the position is not associated with Alice in the ovMarket
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(alice, posId)));
        assertEq(fractionRemaining, 0);

        // the position is associated with Shiva in the ovMarket
        (,,,,,,, fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertGt(fractionRemaining, 0);

        // the position is associated with Alice in Shiva
        assertEq(shiva.positionOwners(ovMarket, posId), alice);
    }

    // Alice and Bob build positions, after each build, Shiva should not have OVL tokens
    function test_build_noOVL() public {
        uint256 numberWithDecimals = 1234567890123456789;
        vm.startPrank(alice);
        buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);
        assertEq(ovToken.balanceOf(address(shiva)), 0);
        vm.stopPrank();

        vm.startPrank(bob);
        buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);
        assertEq(ovToken.balanceOf(address(shiva)), 0);
        vm.stopPrank();
    }

    // Build leverage less than minimum
    function test_build_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(ovMarket, ONE, ONE - 1, true, priceLimit);
    }

    // Build fail not enough allowance
    function test_build_notEnoughAllowance() public {
        deal(address(ovToken), charlie, 1000e18);
        vm.startPrank(charlie);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(ovMarket, ONE, ONE, true, priceLimit);
    }

    // Build fail enough allowance but not enough balance considering the trading fee
    function test_build_notEnoughBalance() public {
        deal(address(ovToken), charlie, ONE);
        vm.startPrank(charlie);
        ovToken.approve(address(shiva), type(uint256).max);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.build(ovMarket, ONE, ONE, true, priceLimit);
    }

    function test_build_pol_stake() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), notional);
    }

    // Unwind method tests

    // Alice builds a position and then unwinds it through Shiva
    function test_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, ONE, BASIC_SLIPPAGE);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);
    }

    function test_partial_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        // Alice unwinds 50% of her position through Shiva
        unwindPosition(posId, 5e17, BASIC_SLIPPAGE);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 5000);

        // The position is still associated with Alice in Shiva
        assertEq(shiva.positionOwners(ovMarket, posId), alice);
    }

    function test_unwind_notOwner(
        bool isLong
    ) public {
        // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, isLong);
        vm.stopPrank();
        // Bob tries to unwind Alice's position through Shiva
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, BASIC_SLIPPAGE, !isLong);
        vm.startPrank(bob);
        vm.expectRevert();
        shiva.unwind(ovMarket, posId, ONE, priceLimit);
    }

    function test_unwind_pol_unstake() public {
        vm.startPrank(alice);
        uint256 collateral = 2e18;
        uint256 leverage = 3e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), notional);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, ONE, 1);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);

        assertEq(rewardVault.balanceOf(alice), 0);
    }

    function test_partial_unwind_pol_unstake() public {
        vm.startPrank(alice);
        uint256 collateral = 2e18;
        uint256 leverage = 3e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), notional);

        // Alice unwinds her position through Shiva
        uint256 fraction = ONE / 2;
        unwindPosition(posId, fraction, 1);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 10_000 * (ONE - fraction) / ONE);

        assertEq(rewardVault.balanceOf(alice), (ONE -fraction).mulUp(notional));

        unwindPosition(posId, fraction, 1);
        assertEq(rewardVault.balanceOf(alice), (ONE -fraction).mulUp(ONE -fraction).mulUp(notional));

        unwindPosition(posId, ONE, 1);
        assertEq(rewardVault.balanceOf(alice), 0);
    }

    function testFuzz_partial_unwind_pol_unstake(uint256 collateral, uint256 leverage, uint256 fraction) public {
        collateral =
            bound(collateral, ovMarket.params(uint256(Risk.Parameters.MinCollateral)), 500e18);
        leverage = bound(leverage, 1e18, ovMarket.params(uint256(Risk.Parameters.CapLeverage)));
        fraction = bound(leverage, 1e17, 9e17);
        console.log(fraction, "fraction");
        uint256 roundedFraction = fraction - fraction % 1e14;
        console.log(roundedFraction, "roundedFraction");
        vm.startPrank(alice);
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        console.log(notional, "notional");
        assertEq(rewardVault.balanceOf(alice), notional);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, fraction, 1);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 10_000 * (ONE - roundedFraction) / ONE, "fraction remaining");

        assertApproxEqAbs(rewardVault.balanceOf(alice), (ONE - roundedFraction).mulDown(notional), 1, "reward balance, 1st unwind");

        {
            (
                uint96 notionalInitial_,
                uint96 debtInitial_,
                int24 midTick_,
                int24 entryTick_,
                bool isLong_,
                bool liquidated_,
                uint240 oiShares_,
                uint16 fractionRemaining_
            ) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
            Position.Info memory positionInfo = Position.Info(
                notionalInitial_,
                debtInitial_,
                midTick_,
                entryTick_,
                isLong_,
                liquidated_,
                oiShares_,
                fractionRemaining_
            );
            assertEq(rewardVault.balanceOf(alice), Position.notionalInitial(positionInfo, ONE), "1st unwind: reward balance != remaining intial notional");
        }

        unwindPosition(posId, fraction, 1);
        // estimated notional remaining on position
        assertApproxEqRel(rewardVault.balanceOf(alice), (ONE - roundedFraction).mulDown(ONE - roundedFraction).mulDown(notional), 1e16, "reward balance, 2nd unwind");
        // staked balance should be lower than or equal the estimated notional remaining on position (+1 for rounding error)
        assertLeDecimal(rewardVault.balanceOf(alice), (ONE - roundedFraction).mulDown(ONE - roundedFraction).mulDown(notional) + 1, 1e18, "reward balance, 2nd unwind LE");

        {
            (
                uint96 notionalInitial_,
                uint96 debtInitial_,
                int24 midTick_,
                int24 entryTick_,
                bool isLong_,
                bool liquidated_,
                uint240 oiShares_,
                uint16 fractionRemaining_
            ) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
            Position.Info memory positionInfo = Position.Info(
                notionalInitial_,
                debtInitial_,
                midTick_,
                entryTick_,
                isLong_,
                liquidated_,
                oiShares_,
                fractionRemaining_
            );
            assertEq(rewardVault.balanceOf(alice), Position.notionalInitial(positionInfo, ONE), "2nd unwind: reward balance != remaining intial notional");
        }

        unwindPosition(posId, ONE, 1);
        (,,,,,,, uint16 fractionRemaining3) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining3, 0, "3rd unwind: fraction remaining != 0");
        assertEq(rewardVault.balanceOf(alice), 0, "3rd unwind: reward balance != 0");
    }

    // BuildSingle method tests

    // Alice builds a position through Shiva and then builds another one
    function test_buildSingle() public {
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        assertEq(ovToken.balanceOf(address(shiva)), 0);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        uint256 posId2 = shiva.buildSingle(Shiva.BuildSingleParams(ONE, ONE, posId1, ovMarket, BASIC_SLIPPAGE));

        // the first position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId1)));
        assertEq(fractionRemaining, 0);

        // the second position is associated with Alice in Shiva
        assertEq(shiva.positionOwners(ovMarket, posId2), alice);

        // the second position is not associated with Alice in the ovMarket
        (,,,,,,, fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(alice, posId2)));
        assertEq(fractionRemaining, 0);

        // shiva has no tokens after the transaction
        assertEq(ovToken.balanceOf(address(shiva)), 0);
    }

    // Alice builds a position through Shiva and then builds another one
    function testFuzz_buildSingle(uint256 collateral, uint256 leverage) public {
        collateral =
            bound(collateral, ovMarket.params(uint256(Risk.Parameters.MinCollateral)), 500e18);
        leverage = bound(leverage, ONE, ovMarket.params(uint256(Risk.Parameters.CapLeverage)));

        vm.startPrank(alice);
        uint256 posId1 = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);

        assertEq(ovToken.balanceOf(address(shiva)), 0);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        uint256 posId2 =
            shiva.buildSingle(Shiva.BuildSingleParams(collateral, leverage, posId1, ovMarket, BASIC_SLIPPAGE));

        // the first position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId1)));
        assertEq(fractionRemaining, 0);

        // the second position is associated with Alice in Shiva
        assertEq(shiva.positionOwners(ovMarket, posId2), alice);

        // the second position is not associated with Alice in the ovMarket
        (,,,,,,, fractionRemaining) = ovMarket.positions(keccak256(abi.encodePacked(alice, posId2)));
        assertEq(fractionRemaining, 0);

        // shiva has no tokens after the transaction
        assertEq(ovToken.balanceOf(address(shiva)), 0);
    }

    // Alice and Bob build positions, after each build, Shiva should not have OVL tokens
    function test_buildSingle_noOVL() public {
        uint256 numberWithDecimals = 1234567890123456789;
        vm.startPrank(alice);
        uint256 posId1 = buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        shiva.buildSingle(
            Shiva.BuildSingleParams(numberWithDecimals, numberWithDecimals, posId1, ovMarket, BASIC_SLIPPAGE)
        );
        assertEq(ovToken.balanceOf(address(shiva)), 0);

        vm.startPrank(bob);
        uint256 posId3 = buildPosition(numberWithDecimals, numberWithDecimals, BASIC_SLIPPAGE, true);

        // Bob builds a second position after a while
        vm.warp(block.timestamp + 1000);

        shiva.buildSingle(
            Shiva.BuildSingleParams(numberWithDecimals, numberWithDecimals, posId3, ovMarket, BASIC_SLIPPAGE)
        );
        assertEq(ovToken.balanceOf(address(shiva)), 0);
    }

    // BuildSingle fail previous position not owned by the caller
    function test_buildSingle_noPreviousPosition() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shiva.buildSingle(Shiva.BuildSingleParams(ONE, ONE, 0, ovMarket, BASIC_SLIPPAGE));
    }

    // BuildSingle fail leverage less than minimum
    function test_buildSingle_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.buildSingle(Shiva.BuildSingleParams(ONE, ONE - 1, posId, ovMarket, BASIC_SLIPPAGE));
    }

    // BuildSingle fail slippage greater than 10000
    function test_buildSingle_slippageGreaterThan100() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        vm.expectRevert();
        shiva.buildSingle(Shiva.BuildSingleParams(ONE, ONE, posId, ovMarket, 11000));
    }

    // function test_buildOnBehalfOf_ownership(bool isLong) public {
    //     uint256 deadline = block.timestamp;
    //     uint256 collateral = 10e18;
    //     uint256 leverage = ONE;
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
    //     assertEq(shiva.positionOwners(ovMarket, posId), alice);
    // }

    // function test_unwindOnBehalfOf_notOwner(bool isLong) public {
    //     // Alice builds a position through Shiva
    //     vm.prank(alice);
    //     uint256 posId = shiva.build(
    //         ovMarket, 10e18, ONE, isLong, isLong ? type(uint256).max : 0
    //     );

    //     // TODO: use EIP712 and add random nonces that can be nullified by the owner

    //     // Bob makes a signature to try to unwind Alice's position through Shiva
    //     uint256 deadline = block.timestamp;
    //     uint256 fraction = ONE;
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
    //     // TODO implement Shiva.NotPositionOwner.selector
    //     // vm.expectRevert(Shiva.NotPositionOwner.selector);
    //     shiva.unwindOnBehalfOf(ovMarket, bob, signature, deadline, posId, fraction, priceLimit);
    // }
}
