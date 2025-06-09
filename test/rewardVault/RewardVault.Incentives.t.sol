// SPDX-License-Identifier: MIT
pragma solidity <=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RewardVault} from "src/rewardVault/RewardVault.sol";
import {RewardVaultFactory} from "src/rewardVault/RewardVaultFactory.sol";
import {IPOLErrors} from "src/rewardVault/berachain/IPOLErrors.sol";
import {FactoryOwnable} from "src/rewardVault/berachain/FactoryOwnable.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RewardVaultIncentivesTest is Test {
    // Tokens
    MockERC20 stakingToken;
    MockERC20 bgt;
    MockERC20 incentiveToken;

    // Contracts
    RewardVaultFactory factory;
    RewardVault rewardVault;

    // Users
    address deployer;
    address alice;
    address incentiveManager;

    uint256 constant ONE = 1e18;
    uint256 constant MAX_INCENTIVE_RATE = 1e36;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        incentiveManager = makeAddr("incentiveManager");

        vm.label(deployer, "Deployer");
        vm.label(alice, "Alice");
        vm.label(incentiveManager, "IncentiveManager");

        vm.startPrank(deployer);

        // Deploy tokens
        stakingToken = new MockERC20("Staking Token", "STK", 18);
        bgt = new MockERC20("Berachain Governance Token", "BGT", 18);
        incentiveToken = new MockERC20("Incentive Token", "INC", 18);

        // Deploy implementations
        RewardVault rewardVaultImplementation = new RewardVault();
        RewardVaultFactory rewardVaultFactoryImplementation = new RewardVaultFactory();

        // Deploy factory proxy
        bytes memory rewardVaultFactoryData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(bgt),
            deployer,
            address(rewardVaultImplementation)
        );
        factory = RewardVaultFactory(
            address(new ERC1967Proxy(address(rewardVaultFactoryImplementation), rewardVaultFactoryData))
        );
        
        // Grant roles
        factory.grantRole(factory.VAULT_MANAGER_ROLE(), deployer);

        // Create a vault
        address vaultAddress = factory.createRewardVault(address(stakingToken));
        rewardVault = RewardVault(vaultAddress);

        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      WHITELISTING                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_whitelist_incentive_token() public {
        vm.startPrank(deployer);
        
        uint256 minRate = 100 * ONE;
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);

        (uint256 _minIncentiveRate, uint256 _incentiveRate, , address _manager) = rewardVault.incentives(address(incentiveToken));

        assertEq(_minIncentiveRate, minRate, "minIncentiveRate incorrect");
        assertEq(_incentiveRate, minRate, "incentiveRate should be set to min");
        assertEq(_manager, incentiveManager, "manager incorrect");
        assertEq(rewardVault.getWhitelistedTokensCount(), 1, "whitelisted token count incorrect");
        assertEq(rewardVault.getWhitelistedTokens()[0], address(incentiveToken), "whitelisted token address incorrect");
        
        vm.stopPrank();
    }

    function test_revert_whitelist_not_owner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FactoryOwnable.OwnableUnauthorizedAccount.selector, alice));
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 100 * ONE, incentiveManager);
    }
    
    function test_revert_whitelist_zero_min_rate() public {
        vm.prank(deployer);
        vm.expectRevert(IPOLErrors.MinIncentiveRateIsZero.selector);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 0, incentiveManager);
    }

    function test_revert_whitelist_rate_too_high() public {
        vm.prank(deployer);
        vm.expectRevert(IPOLErrors.IncentiveRateTooHigh.selector);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), MAX_INCENTIVE_RATE + 1, incentiveManager);
    }

    function test_revert_whitelist_zero_address() public {
        vm.startPrank(deployer);
        vm.expectRevert(IPOLErrors.ZeroAddress.selector);
        rewardVault.whitelistIncentiveToken(address(0), 100 * ONE, incentiveManager);
        
        vm.expectRevert(IPOLErrors.ZeroAddress.selector);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 100 * ONE, address(0));
        vm.stopPrank();
    }

    function test_revert_whitelist_already_whitelisted() public {
        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 100 * ONE, incentiveManager);

        vm.expectRevert(IPOLErrors.TokenAlreadyWhitelistedOrLimitReached.selector);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 100 * ONE, incentiveManager);
        vm.stopPrank();
    }

    function test_revert_whitelist_limit_reached() public {
        // Default limit is 3
        MockERC20 token1 = new MockERC20("T1", "T1", 18);
        MockERC20 token2 = new MockERC20("T2", "T2", 18);
        MockERC20 token3 = new MockERC20("T3", "T3", 18);
        MockERC20 token4 = new MockERC20("T4", "T4", 18);

        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(token1), 1, incentiveManager);
        rewardVault.whitelistIncentiveToken(address(token2), 1, incentiveManager);
        rewardVault.whitelistIncentiveToken(address(token3), 1, incentiveManager);

        vm.expectRevert(IPOLErrors.TokenAlreadyWhitelistedOrLimitReached.selector);
        rewardVault.whitelistIncentiveToken(address(token4), 1, incentiveManager);
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 WHITELIST MANAGEMENT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_set_max_incentive_tokens() public {
        assertEq(rewardVault.maxIncentiveTokensCount(), 3); // check default
        vm.prank(deployer);
        rewardVault.setMaxIncentiveTokensCount(5);
        assertEq(rewardVault.maxIncentiveTokensCount(), 5);
    }

    function test_revert_set_max_incentive_tokens_not_owner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FactoryOwnable.OwnableUnauthorizedAccount.selector, alice));
        rewardVault.setMaxIncentiveTokensCount(5);
    }

    function test_revert_set_max_incentive_tokens_too_low() public {
        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 1, incentiveManager);
        
        vm.expectRevert(IPOLErrors.InvalidMaxIncentiveTokensCount.selector);
        rewardVault.setMaxIncentiveTokensCount(0);
        vm.stopPrank();
    }

    function test_remove_incentive_token() public {
        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 1, incentiveManager);
        assertEq(rewardVault.getWhitelistedTokensCount(), 1);

        rewardVault.removeIncentiveToken(address(incentiveToken));
        assertEq(rewardVault.getWhitelistedTokensCount(), 0);
        (uint256 minRate, , , ) = rewardVault.incentives(address(incentiveToken));
        assertEq(minRate, 0, "incentive should be deleted");
        vm.stopPrank();
    }

    function test_revert_remove_incentive_token_not_manager() public {
        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 1, incentiveManager);
        vm.stopPrank();

        vm.prank(alice); // Not a vault manager
        vm.expectRevert(abi.encodeWithSelector(FactoryOwnable.OwnableUnauthorizedAccount.selector, alice));
        rewardVault.removeIncentiveToken(address(incentiveToken));
    }
    
    function test_revert_remove_unlisted_token() public {
        vm.prank(deployer);
        vm.expectRevert(IPOLErrors.TokenNotWhitelisted.selector);
        rewardVault.removeIncentiveToken(address(incentiveToken));
    }

    function test_update_incentive_manager() public {
        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 1, incentiveManager);
        
        address newManager = makeAddr("newManager");
        rewardVault.updateIncentiveManager(address(incentiveToken), newManager);

        (, , , address manager) = rewardVault.incentives(address(incentiveToken));
        assertEq(manager, newManager);
        vm.stopPrank();
    }

    function test_revert_update_incentive_manager_not_owner() public {
        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 1, incentiveManager);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FactoryOwnable.OwnableUnauthorizedAccount.selector, alice));
        rewardVault.updateIncentiveManager(address(incentiveToken), alice);
    }

    function test_revert_update_incentive_manager_zero_address() public {
        vm.startPrank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), 1, incentiveManager);
        
        vm.expectRevert(IPOLErrors.ZeroAddress.selector);
        rewardVault.updateIncentiveManager(address(incentiveToken), address(0));
        vm.stopPrank();
    }

    function test_revert_update_manager_unlisted_token() public {
        vm.prank(deployer);
        vm.expectRevert(IPOLErrors.TokenNotWhitelisted.selector);
        rewardVault.updateIncentiveManager(address(incentiveToken), alice);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 ADDING INCENTIVES                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    
    function test_add_incentive() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);

        // Fund and approve manager
        incentiveToken.mint(incentiveManager, 1_000 * ONE);
        vm.startPrank(incentiveManager);
        incentiveToken.approve(address(rewardVault), type(uint256).max);

        uint256 addAmount = 200 * ONE;
        uint256 newRate = 150 * ONE;
        rewardVault.addIncentive(address(incentiveToken), addAmount, newRate);

        (, uint256 incentiveRate, uint256 amountRemaining, ) = rewardVault.incentives(address(incentiveToken));
        assertEq(incentiveRate, newRate);
        assertEq(amountRemaining, addAmount);
        assertEq(incentiveToken.balanceOf(address(rewardVault)), addAmount);
        vm.stopPrank();
    }

    function test_add_incentive_increase_rate() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);

        // Fund and approve manager
        incentiveToken.mint(incentiveManager, 1_000 * ONE);
        vm.startPrank(incentiveManager);
        incentiveToken.approve(address(rewardVault), type(uint256).max);

        rewardVault.addIncentive(address(incentiveToken), 200 * ONE, 150 * ONE);

        // add more with a higher rate
        uint256 newAddAmount = 300 * ONE;
        uint256 newHigherRate = 200 * ONE;
        rewardVault.addIncentive(address(incentiveToken), newAddAmount, newHigherRate);

        (, uint256 incentiveRate, uint256 amountRemaining, ) = rewardVault.incentives(address(incentiveToken));
        assertEq(incentiveRate, newHigherRate);
        assertEq(amountRemaining, 200 * ONE + newAddAmount);
        vm.stopPrank();
    }

    function test_revert_add_incentive_not_manager() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);
        
        vm.prank(alice); // not the manager
        vm.expectRevert(IPOLErrors.NotIncentiveManager.selector);
        rewardVault.addIncentive(address(incentiveToken), 200 * ONE, 150 * ONE);
    }

    function test_revert_add_incentive_decrease_rate_with_balance() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);
        
        // Fund and approve manager
        incentiveToken.mint(incentiveManager, 1_000 * ONE);
        vm.startPrank(incentiveManager);
        incentiveToken.approve(address(rewardVault), type(uint256).max);

        // Set an initial rate
        rewardVault.addIncentive(address(incentiveToken), 200 * ONE, 150 * ONE);

        // Try to add more with a lower rate
        vm.expectRevert(IPOLErrors.InvalidIncentiveRate.selector);
        rewardVault.addIncentive(address(incentiveToken), 200 * ONE, 140 * ONE);
        vm.stopPrank();
    }
    
    function test_revert_add_incentive_amount_below_min_rate() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);

        vm.prank(incentiveManager);
        vm.expectRevert(IPOLErrors.AmountLessThanMinIncentiveRate.selector);
        rewardVault.addIncentive(address(incentiveToken), minRate - 1, minRate);
    }

    function test_revert_add_incentive_rate_below_min() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);
        
        vm.prank(incentiveManager);
        vm.expectRevert(IPOLErrors.InvalidIncentiveRate.selector);
        rewardVault.addIncentive(address(incentiveToken), minRate, minRate - 1);
    }

    function test_account_incentives() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);

        // Manager "accidentally" sends tokens
        uint256 transferAmount = 500 * ONE;
        incentiveToken.mint(incentiveManager, transferAmount);
        vm.prank(incentiveManager);
        incentiveToken.transfer(address(rewardVault), transferAmount);
        
        // now account for them
        vm.startPrank(incentiveManager);
        rewardVault.accountIncentives(address(incentiveToken), transferAmount);
        
        (, , uint256 amountRemaining, ) = rewardVault.incentives(address(incentiveToken));
        assertEq(amountRemaining, transferAmount);
        vm.stopPrank();
    }

    function test_revert_account_incentives_not_enough_balance() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);
        
        vm.prank(incentiveManager);
        vm.expectRevert(IPOLErrors.NotEnoughBalance.selector);
        rewardVault.accountIncentives(address(incentiveToken), 500 * ONE);
    }

    function test_revert_account_incentives_amount_below_min() public {
        uint256 minRate = 100 * ONE;
        vm.prank(deployer);
        rewardVault.whitelistIncentiveToken(address(incentiveToken), minRate, incentiveManager);
        
        vm.prank(incentiveManager);
        vm.expectRevert(IPOLErrors.AmountLessThanMinIncentiveRate.selector);
        rewardVault.accountIncentives(address(incentiveToken), minRate - 1);
    }
} 