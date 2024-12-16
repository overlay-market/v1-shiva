// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Shiva} from "src/Shiva.sol";
import {IOverlayV1Market} from "v1-core/contracts/interfaces/IOverlayV1Market.sol";
import {IOverlayV1Token, LIQUIDATE_CALLBACK_ROLE} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {IOverlayV1State} from "v1-periphery/contracts/interfaces/IOverlayV1State.sol";
import {IOverlayV1ChainlinkFeed} from "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";
import {Constants} from "./utils/Constants.sol";
import {Utils} from "src/utils/Utils.sol";
import {MarketImpersonator} from "./utils/MarketImpersonator.sol";
import {OverlayV1Factory} from "v1-core/contracts/OverlayV1Factory.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";
import {Position} from "v1-core/contracts/libraries/Position.sol";
import {IBerachainRewardsVault, IBerachainRewardsVaultFactory} from "../src/interfaces/berachain/IRewardVaults.sol";
import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {IFluxAggregator} from "src/interfaces/aggregator/IFluxAggregator.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ShivaNewFactoryTest is Test, ShivaTestBase {
    using FixedPoint for uint256;

    function setUp() public override {
        vm.createSelectFork(vm.envString(Constants.getForkedNetworkRPC()), Constants.getForkBlock());

        vm.startPrank(deployer);
        ovToken = deployToken();
        ovFactory = deployFactory(ovToken);
        ovMarket = deployMarket(ovFactory, Constants.getEthdFeed());
        ovState = deployPeriphery(ovFactory);

        IBerachainRewardsVaultFactory vaultFactory = IBerachainRewardsVaultFactory(
            0x2B6e40f65D82A0cB98795bC7587a71bfa49fBB2B
        );
        Shiva shivaImplementation = new Shiva();
        string memory functionName = "initialize(address,address,address)";
        bytes memory data = abi.encodeWithSignature(functionName, address(ovToken), address(ovState), address(vaultFactory));
        shiva = Shiva(address(new ERC1967Proxy(address(shivaImplementation), data)));
        rewardVault = shiva.rewardVault();

        // configure shiva
        ovToken.grantRole(LIQUIDATE_CALLBACK_ROLE, address(shiva));
        vm.stopPrank();

        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        charlie = vm.addr(charliePk);
        automator = makeAddr("automator");
        guardian = Constants.getGuardianAddress();

        labelAddresses();
        setInitialBalancesAndApprovals();
        
        vm.startPrank(guardian);
        shiva.addFactory(ovFactory);
        vm.stopPrank();
    }

    // Build method tests

    // Alice builds a position through Shiva
    function test_build() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, 1, true);

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
        buildPosition(numberWithDecimals, numberWithDecimals, 1, true);
        assertEq(ovToken.balanceOf(address(shiva)), 0);
        vm.stopPrank();

        vm.startPrank(bob);
        buildPosition(numberWithDecimals, numberWithDecimals, 1, true);
        assertEq(ovToken.balanceOf(address(shiva)), 0);
        vm.stopPrank();
    }

    // Build leverage less than minimum
    function test_build_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, 1, true);
        vm.expectRevert();
        shiva.build(ShivaStructs.Build(ovMarket, true, ONE, ONE - 1, priceLimit));
    }

    // Build fail not enough allowance
    function test_build_notEnoughAllowance() public {
        deal(address(ovToken), charlie, 1000e18);
        vm.startPrank(charlie);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, 1, true);
        vm.expectRevert();
        shiva.build(ShivaStructs.Build(ovMarket, true, ONE, ONE, priceLimit));

    }

    // Build fail enough allowance but not enough balance considering the trading fee
    function test_build_notEnoughBalance() public {
        deal(address(ovToken), charlie, ONE);
        vm.startPrank(charlie);
        ovToken.approve(address(shiva), type(uint256).max);
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, 1, true);
        vm.expectRevert();
        shiva.build(ShivaStructs.Build(ovMarket, true, ONE, ONE, priceLimit));
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
        uint256 posId = buildPosition(ONE, ONE, 1, true);

        // Alice unwinds her position through Shiva
        unwindPosition(posId, ONE, 1);

        // the position is successfully unwound
        (,,,,,,, uint16 fractionRemaining) =
            ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertEq(fractionRemaining, 0);
    }

    function test_partial_unwind() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, 1, true);

        // Alice unwinds 50% of her position through Shiva
        unwindPosition(posId, 5e17, 1);

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
        uint256 posId = buildPosition(ONE, ONE, 1, isLong);
        vm.stopPrank();
        // Bob tries to unwind Alice's position through Shiva
        uint256 priceLimit = Utils.getEstimatedPrice(ovState, ovMarket, ONE, ONE, 1, !isLong);
        vm.startPrank(bob);
        vm.expectRevert();
        shiva.unwind(ShivaStructs.Unwind(ovMarket, posId, ONE, priceLimit));
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
        ovToken.transfer(address(ovMarket), 2); // TODO remove this - sending ov to avoid out of balance revert
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // shiva should stake notional amount of receipt tokens on behalf of the user on the reward vault
        uint256 notional = collateral.mulUp(leverage);
        console.log(notional, "notional");
        assertEq(rewardVault.balanceOf(alice), notional);

        // Alice unwinds her position through Shiva
        vm.warp(block.timestamp + 1000);
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

        vm.warp(block.timestamp + 1000);
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

        console.log(ovToken.balanceOf(address(ovMarket)), "balance of market beofre last unwind");
        vm.warp(block.timestamp + 1000);
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
        uint256 posId1 = buildPosition(ONE, ONE, 1, true);

        assertEq(ovToken.balanceOf(address(shiva)), 0);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        uint256 posId2 = shiva.buildSingle(ShivaStructs.BuildSingle(ovMarket, 1, ONE, ONE, posId1));

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
        leverage = bound(leverage, 1e18, ovMarket.params(uint256(Risk.Parameters.CapLeverage)));

        vm.startPrank(alice);
        uint256 posId1 = buildPosition(1e18, 1e18, 1, true);

        assertEq(ovToken.balanceOf(address(shiva)), 0);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        uint256 posId2 =
            shiva.buildSingle(ShivaStructs.BuildSingle(ovMarket, 1, collateral, leverage, posId1));

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
        uint256 posId1 = buildPosition(numberWithDecimals, numberWithDecimals, 1, true);

        // Alice builds a second position after a while
        vm.warp(block.timestamp + 1000);

        shiva.buildSingle(
            ShivaStructs.BuildSingle(ovMarket, 1, numberWithDecimals, numberWithDecimals, posId1)
        );
        assertEq(ovToken.balanceOf(address(shiva)), 0);

        vm.startPrank(bob);
        uint256 posId3 = buildPosition(numberWithDecimals, numberWithDecimals, 1, true);

        // Bob builds a second position after a while
        vm.warp(block.timestamp + 1000);

        shiva.buildSingle(
            ShivaStructs.BuildSingle(ovMarket, 1, numberWithDecimals, numberWithDecimals, posId3)
        );
        assertEq(ovToken.balanceOf(address(shiva)), 0);
    }

    // BuildSingle fail previous position not owned by the caller
    function test_buildSingle_noPreviousPosition() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shiva.buildSingle(ShivaStructs.BuildSingle(ovMarket, 1, ONE, ONE, 0));
    }

    // BuildSingle fail leverage less than minimum
    function test_buildSingle_leverageLessThanMinimum() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, 1, true);
        vm.expectRevert();
        shiva.buildSingle(ShivaStructs.BuildSingle(ovMarket, 1, ONE, ONE - 1, posId));
    }

    // BuildSingle fail slippage greater than 100
    function test_buildSingle_slippageGreaterThan100() public {
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, 1, true);
        vm.expectRevert("Shiva:slp>10000");
        buildSinglePosition(ONE, ONE, posId, 11000);
    }

    // test liquidate

    function test_liquidate_pol() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // submit a new round with price = prevPrice / 2 to make the posId liquidatable
        {
            IFluxAggregator aggregator = IFluxAggregator(IOverlayV1ChainlinkFeed(ovMarket.feed()).aggregator());
            address oracle = aggregator.getOracles()[0];
            int256 halfPrice = aggregator.latestAnswer()/2;

            vm.startPrank(oracle);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60*60);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60*60);
        }
        assertTrue(ovState.liquidatable(ovMarket, address(shiva), posId));

        // liquidate alice's position
        vm.startPrank(bob);
        ovMarket.liquidate(address(shiva), posId);
        (
            , //uint96 notionalInitial_,
            , //uint96 debtInitial_,
            , //int24 midTick_,
            , //int24 entryTick_,
            , //bool isLong_,
            bool liquidated_,
            , //uint240 oiShares_,
            //uint16 fractionRemaining_
        ) = ovMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertTrue(liquidated_);

        // rewards balance should be 0 after the position is liquidated
        assertEq(rewardVault.balanceOf(alice), 0);
    }

    function test_revert_pol_overlayMarketLiquidateCallback_called_by_non_market() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        vm.startPrank(bob);
        vm.expectRevert();
        shiva.overlayMarketLiquidateCallback(posId);
        assertNotEq(rewardVault.balanceOf(alice), 0);
    }

    function test_pol_overlayMarketLiquidateCallback_called_by_impersonator_market() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        vm.startPrank(bob);
        // vm.expectRevert();
        MarketImpersonator impersonator = new MarketImpersonator();
        impersonator.impersonateLiquidation(address(shiva), posId, uint96(leverage.mulDown(collateral)));
        assertEq(rewardVault.balanceOf(alice), leverage.mulUp(collateral));
    }

    function test_pol_withdraw_emergencyWithdraw_function() public {
         // Alice builds a position through Shiva
        vm.startPrank(alice);
        uint256 posId = buildPosition(ONE, ONE, BASIC_SLIPPAGE, true);
        assertEq(rewardVault.balanceOf(alice), ONE);

        unwindPosition(posId, 0.123e18, BASIC_SLIPPAGE);
        vm.stopPrank();

        vm.startPrank(Constants.getGovernorAddress());
        ovFactory.shutdown(ovMarket.feed());
        vm.stopPrank();

        vm.startPrank(alice);
        shiva.emergencyWithdraw(ovMarket, posId, alice);
        vm.stopPrank();

        assertEq(rewardVault.balanceOf(alice), 0);
    }
}
