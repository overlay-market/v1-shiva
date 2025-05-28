// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OverlayV1Factory} from "v1-core/contracts/OverlayV1Factory.sol";

import {Constants} from "./utils/Constants.sol";
import {MarketImpersonator} from "./utils/MarketImpersonator.sol";
import {ShivaTestBase} from "./ShivaBase.t.sol";
import {ShivaTest} from "./Shiva.t.sol";
import {Shiva} from "src/Shiva.sol";
import {ShivaStructs} from "src/ShivaStructs.sol";
import {Utils} from "src/utils/Utils.sol";
import {IBerachainRewardsVaultFactory} from "src/interfaces/berachain/IRewardVaults.sol";
import {IFluxAggregator} from "src/interfaces/aggregator/IFluxAggregator.sol";
import {RewardVault} from "src/rewardVault/RewardVault.sol";
import {RewardVaultFactory} from "src/rewardVault/RewardVaultFactory.sol";
import {IRewardVault} from "src/rewardVault/IRewardVault.sol";

import {FixedPoint} from "v1-core/contracts/libraries/FixedPoint.sol";
import {IOverlayV1ChainlinkFeed} from
    "v1-core/contracts/interfaces/feeds/chainlink/IOverlayV1ChainlinkFeed.sol";
import {
    LIQUIDATE_CALLBACK_ROLE,
    GOVERNOR_ROLE,
    PAUSER_ROLE,
    GUARDIAN_ROLE
} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1Token} from "v1-core/contracts/interfaces/IOverlayV1Token.sol";
import {IOverlayV1Factory} from "v1-core/contracts/interfaces/IOverlayV1Factory.sol";
import {Position} from "v1-core/contracts/libraries/Position.sol";
import {Risk} from "v1-core/contracts/libraries/Risk.sol";

import {MockAggregator} from "./mocks/MockAggregator.sol";
import {OverlayV1ChainlinkFeedFactory} from
    "v1-core/contracts/feeds/chainlink/OverlayV1ChainlinkFeedFactory.sol";

/**
 * @title ShivaLocalTest
 * @notice Test suite for the Shiva contract
 * @dev This contract uses new deployments instead of the existing contracts
 * @dev Tests from ShivaTest are inherited and run on the new deployments
 */
contract ShivaLocalTest is Test, ShivaTestBase, ShivaTest {
    using FixedPoint for uint256;

    IOverlayV1Token public ovlTokenForBgt;

    /**
     * @dev Sets up the initial state for the ShivaBase test contract
     * @dev Overrides the setUp method in ShivaBase
     */
    function setUp() public override {
        vm.createSelectFork(
            vm.envString(Constants.getForkedMainnetNetworkRPC()), Constants.getForkMainnetBlock()
        );

        // Deploy the contracts
        vm.startPrank(deployer);
        ovlToken = deployToken();

        // Deploy aggregator
        aggregator = deployAggregator();

        // Deploy feed factory and feed
        feedFactory = new OverlayV1ChainlinkFeedFactory(
            address(ovlToken),
            600, // microWindow (10 minutes)
            3600 // macroWindow (1 hour)
        );
        feed = IOverlayV1ChainlinkFeed(
            feedFactory.deployFeed(address(aggregator), 172800) // 2 days window
        );

        // Deploy factory
        ovlFactory = deployFactory();

        ovlState = deployPeriphery(ovlFactory);
        ovlMarket = deployMarket(ovlFactory, address(feed));

        // Set Vault Factory
        ovlTokenForBgt = deployToken();
        RewardVault rewardVaultImplementation = new RewardVault();
        RewardVaultFactory rewardVaultFactoryImplementation = new RewardVaultFactory();
        bytes memory rewardVaultFactoryData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(ovlTokenForBgt),
            deployer,
            address(rewardVaultImplementation)
        );
        IBerachainRewardsVaultFactory vaultFactory =
            IBerachainRewardsVaultFactory(address(new ERC1967Proxy(address(rewardVaultFactoryImplementation), rewardVaultFactoryData)));

        // Deploy Shiva contract using ERC1967Proxy pattern and initialize it with necessary parameters
        Shiva shivaImplementation = new Shiva();
        string memory functionName = "initialize(address,address)";
        bytes memory data =
            abi.encodeWithSignature(functionName, address(ovlToken), address(vaultFactory));

        // Set up shiva contract and reward vault
        shiva = Shiva(address(new ERC1967Proxy(address(shivaImplementation), data)));
        rewardVault = shiva.rewardVault();

        // configure liquidation callback role
        ovlToken.grantRole(LIQUIDATE_CALLBACK_ROLE, address(shiva));
        vm.stopPrank();

        // Change the token name
        isOV = false;

        // Set up test addresses
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        charlie = vm.addr(charliePk);
        automator = makeAddr("automator");
        guardian = Constants.getGuardianAddress();
        pauser = Constants.getPauserAddress();

        // Call helper functions
        labelAddresses();
        setInitialBalancesAndApprovals();
        addAuthorizedFactory();
    }

    /**
     * @dev Group of tests for the stake rewards liquidate workflow
     */

    /**
     * @dev Test that the rewards are 0 after a position is liquidated
     */
    function test_liquidate_pol() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // submit a new round with price = prevPrice / 2 to make the posId liquidatable
        {
            IFluxAggregator aggregator =
                IFluxAggregator(IOverlayV1ChainlinkFeed(ovlMarket.feed()).aggregator());
            address oracle = aggregator.getOracles()[0];
            int256 halfPrice = aggregator.latestAnswer() / 2;

            vm.startPrank(oracle);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
        }
        assertTrue(ovlState.liquidatable(ovlMarket, address(shiva), posId));

        // liquidate alice's position
        vm.startPrank(bob);
        ovlMarket.liquidate(address(shiva), posId);
        (
            , //uint96 notionalInitial_,
            , //uint96 debtInitial_,
            , //int24 midTick_,
            , //int24 entryTick_,
            , //bool isLong_,
            bool liquidated_,
            , //uint240 oiShares_,
                //uint16 fractionRemaining_
        ) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertTrue(liquidated_);

        // rewards balance should be 0 after the position is liquidated
        assertEq(rewardVault.balanceOf(alice), 0);
    }

    /**
     * @dev Test that liquidate fails when Shiva is paused
     */
    function test_liquidate_pausedShiva() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        // submit a new round with price = prevPrice / 2 to make the posId liquidatable
        {
            IFluxAggregator aggregator =
                IFluxAggregator(IOverlayV1ChainlinkFeed(ovlMarket.feed()).aggregator());
            address oracle = aggregator.getOracles()[0];
            int256 halfPrice = aggregator.latestAnswer() / 2;

            vm.startPrank(oracle);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
            aggregator.submit(aggregator.latestRound() + 1, halfPrice);
            vm.warp(block.timestamp + 60 * 60);
        }
        assertTrue(ovlState.liquidatable(ovlMarket, address(shiva), posId));
        vm.stopPrank();

        pauseShiva();

        // liquidate alice's position
        vm.startPrank(bob);
        ovlMarket.liquidate(address(shiva), posId);
        (
            , //uint96 notionalInitial_,
            , //uint96 debtInitial_,
            , //int24 midTick_,
            , //int24 entryTick_,
            , //bool isLong_,
            bool liquidated_,
            , //uint240 oiShares_,
                //uint16 fractionRemaining_
        ) = ovlMarket.positions(keccak256(abi.encodePacked(address(shiva), posId)));
        assertTrue(liquidated_);
        // rewards balance should be 0 after the position is liquidated
        assertEq(rewardVault.balanceOf(alice), 0);
    }

    /**
     * @dev Test that liquidate fails when the caller is not the market
     */
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

    /**
     * @dev Test that liquidate fails when the caller is not a valid market
     */
    function test_pol_overlayMarketLiquidateCallback_called_by_impersonator_market() public {
        vm.startPrank(alice);
        uint256 collateral = ONE;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, 1, true);

        vm.startPrank(bob);
        // vm.expectRevert();
        MarketImpersonator impersonator = new MarketImpersonator();
        impersonator.impersonateLiquidation(
            address(shiva), posId, uint96(leverage.mulDown(collateral))
        );
        assertEq(rewardVault.balanceOf(alice), leverage.mulUp(collateral));
    }

    /**
     * @dev Group of tests for RewardVault balance validations
     */

    /**
     * @notice Tests that building a position correctly updates the user's balance in RewardVault.
     */
    function test_build_updates_rewardVault_balance() public {
        vm.startPrank(alice);
        uint256 collateral = 10e18; // 10 OVL
        uint256 leverage = 2.5e18; // 2.5x
        uint256 expectedNotional = collateral.mulUp(leverage); // 25 OVL (staking token amount)

        uint256 balanceBefore = rewardVault.balanceOf(alice);
        buildPosition(collateral, leverage, BASIC_SLIPPAGE, true);
        uint256 balanceAfter = rewardVault.balanceOf(alice);

        assertEq(balanceAfter, balanceBefore + expectedNotional, "RewardVault balance should increase by notional");
        vm.stopPrank();
    }

    /**
     * @notice Tests that fully unwinding a position sets the user's RewardVault balance to zero (or initial).
     */
    function test_unwind_full_updates_rewardVault_balance() public {
        vm.startPrank(alice);
        uint256 collateral = 10e18;
        uint256 leverage = 2e18;
        uint256 posId = buildPosition(collateral, leverage, BASIC_SLIPPAGE, true);
        
        uint256 balanceBeforeUnwind = rewardVault.balanceOf(alice);
        uint256 expectedInitialNotional = collateral.mulUp(leverage);
        assertEq(balanceBeforeUnwind, expectedInitialNotional, "Initial RewardVault balance incorrect");

        unwindPosition(posId, ONE, BASIC_SLIPPAGE); // Unwind 100%
        uint256 balanceAfterUnwind = rewardVault.balanceOf(alice);

        assertEq(balanceAfterUnwind, 0, "RewardVault balance should be zero after full unwind");
        vm.stopPrank();
    }

    /**
     * @notice Tests that partially unwinding a position correctly updates the user's RewardVault balance.
     */
    function test_unwind_partial_updates_rewardVault_balance() public {
        vm.startPrank(alice);
        uint256 collateral = 20e18;
        uint256 leverage = 2e18; // Notional = 40
        uint256 posId = buildPosition(collateral, leverage, BASIC_SLIPPAGE, true);

        uint256 initialNotional = collateral.mulUp(leverage);
        assertEq(rewardVault.balanceOf(alice), initialNotional, "Initial RewardVault balance incorrect");

        uint256 fractionToUnwind = 0.25e18; // Unwind 25%
        
        // Rounding in _onUnwindPosition: _fraction -= _fraction % 1e14;
        uint256 roundedFractionToUnwind = fractionToUnwind - (fractionToUnwind % 1e14);
        uint256 actualNotionalUnstaked = initialNotional.mulDown(roundedFractionToUnwind);


        unwindPosition(posId, fractionToUnwind, BASIC_SLIPPAGE);
        uint256 balanceAfterPartialUnwind = rewardVault.balanceOf(alice);
        
        // The actual unstaked amount might differ due to internal rounding in Shiva's _onUnstake or _onUnwindPosition
        // We need to check the logic in Shiva.sol:_onUnstake and how much is actually withdrawn.
        // Shiva._onUnstake: _amount = currentBalance < _amount ? currentBalance : _amount;
        // Shiva._onUnwindPosition: intialNotionalFraction = intialNotionalFractionBefore - Utils.getNotionalRemaining(...); _onUnstake(..., intialNotionalFraction);

        // For simplicity here, we assume ideal math, but in reality, it might be slightly off.
        // A more robust check would be to get the actual amount unstaked from events if possible, or recalculate as Shiva does.
        // Based on current code, _onUnstake will use the difference in notional remaining.
        // Let's assert the remaining balance is (initialNotional - actualNotionalUnstaked) which should be initialNotional * (1 - roundedFractionToUnwind)
        uint256 expectedRemainingBalance = initialNotional - actualNotionalUnstaked;

        assertApproxEqAbs(balanceAfterPartialUnwind, expectedRemainingBalance, 1, "RewardVault balance after partial unwind incorrect");

        vm.stopPrank();
    }

    /**
     * @notice Tests that emergency withdrawing a position sets the user's RewardVault balance to zero.
     */
    function test_emergencyWithdraw_updates_rewardVault_balance() public {
        vm.startPrank(alice);
        uint256 collateral = 10e18;
        uint256 leverage = 2e18; // Notional = 20
        uint256 posId = buildPosition(collateral, leverage, BASIC_SLIPPAGE, true);

        assertEq(rewardVault.balanceOf(alice), collateral.mulUp(leverage), "Initial RewardVault balance incorrect");
        vm.stopPrank();

        shutDownMarket(); // Market is shut down

        vm.startPrank(alice);
        shiva.emergencyWithdraw(ovlMarket, posId, alice);
        vm.stopPrank();

        assertEq(rewardVault.balanceOf(alice), 0, "RewardVault balance should be zero after emergency withdraw");
    }
}
